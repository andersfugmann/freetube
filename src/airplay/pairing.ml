module Err = Error
open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay pair-setup handshake and credentials" Stdlib.__MODULE__)

(* Long-term AirPlay pairing credentials. [pairing_id] is the receiver's
   identifier (the persistence key, attached once the handshake completes);
   the key material is stored hex-encoded and handed to pair-verify through
   the byte accessors. *)
type credentials = {
  pairing_id : string;
  controller_pairing_id : string;
  controller_ltsk_hex : string;
  controller_ltpk_hex : string;
  receiver_ltpk_hex : string;
} [@@deriving yojson]


let ( let* ) result f = Result.bind result ~f

let pairing_id t = t.pairing_id
let controller_pairing_id t = t.controller_pairing_id
let controller_ltsk t = Ohex.decode t.controller_ltsk_hex
let receiver_ltpk t = Ohex.decode t.receiver_ltpk_hex

let byte value = String.of_char (Char.of_int_exn value)
let nonce label = String.make 4 '\000' ^ label

let random_hex length = Mirage_crypto_rng.generate length |> Ohex.encode

let check_peer_error message =
  match Tlv8.find Tlv8.tag_error message with
  | None -> Ok message
  | Some error_code when String.is_empty error_code -> Error "peer returned empty error TLV"
  | Some error_code ->
      Error (Stdlib.Printf.sprintf "peer returned error 0x%02x" (Char.to_int (String.get error_code 0)))

let decode_message payload =
  try Ok (Tlv8.decode payload) with
  | exn -> Error (Exn.to_string exn)

let find_required tag name message =
  match Tlv8.find tag message with
  | Some value -> Ok value
  | None -> Error (name ^ " missing from TLV")

let generate_credentials () =
  let controller_ltsk, controller_ltpk = Mirage_crypto_ec.Ed25519.generate () in
  {
    pairing_id = "";
    controller_pairing_id = random_hex 16;
    controller_ltsk_hex = Mirage_crypto_ec.Ed25519.priv_to_octets controller_ltsk |> Ohex.encode;
    controller_ltpk_hex = Mirage_crypto_ec.Ed25519.pub_to_octets controller_ltpk |> Ohex.encode;
    receiver_ltpk_hex = "";
  }

type client_srp_state = {
  srp : Srp.client_state;
  credentials : credentials;
}

type state =
  | Awaiting_m4 of client_srp_state
  | Awaiting_m6 of { encryption_key : string; credentials : credentials }

let build_m1 () =
  Tlv8.encode
    [ Tlv8.tag_method, byte 0x00; Tlv8.tag_sequence_num, byte 0x01 ]

let process_m2 ~password payload =
  let* message = decode_message payload in
  let* message = check_peer_error message in
  let* salt = find_required Tlv8.tag_salt "salt" message in
  let* b_public = find_required Tlv8.tag_public_key "public key" message in
  try
    let srp =
      Srp.generate_client ~password ~random_bytes:(Mirage_crypto_rng.generate 48)
      |> Srp.process_server_challenge ~salt ~b_public
    in
    let credentials = generate_credentials () in
    let m3 =
      Tlv8.encode
        [
          Tlv8.tag_public_key, srp.a_public;
          Tlv8.tag_proof, srp.client_proof;
          Tlv8.tag_sequence_num, byte 0x03;
        ]
    in
    Ok (Awaiting_m4 { srp; credentials }, m3)
  with
  | exn -> Error (Exn.to_string exn)

let process_m4 state payload =
  match state with
  | Awaiting_m4 { srp; credentials } ->
      let* message = decode_message payload in
      let* message = check_peer_error message in
      let* server_proof = find_required Tlv8.tag_proof "server proof" message in
      (match Srp.verify_server_proof srp ~server_proof with
       | false -> Error "server SRP proof verification failed"
       | true ->
           (try
              let encryption_key =
                Hkdf.derive
                  ~salt:"Pair-Setup-Encrypt-Salt"
                  ~info:"Pair-Setup-Encrypt-Info"
                  ~length:32
                  ~ikm:srp.shared_key
              in
              let signing_material =
                Hkdf.derive
                  ~salt:"Pair-Setup-Controller-Sign-Salt"
                  ~info:"Pair-Setup-Controller-Sign-Info"
                  ~length:32
                  ~ikm:srp.shared_key
                ^ credentials.controller_pairing_id
                ^ Ohex.decode credentials.controller_ltpk_hex
              in
              let signature =
                Crypto.ed25519_sign
                  ~private_key:(controller_ltsk credentials)
                  ~message:signing_material
              in
              let plaintext =
                Tlv8.encode
                  [
                    Tlv8.tag_identifier, credentials.controller_pairing_id;
                    Tlv8.tag_public_key, Ohex.decode credentials.controller_ltpk_hex;
                    Tlv8.tag_signature, signature;
                  ]
              in
              let encrypted_data =
                Crypto.chacha20_poly1305_encrypt
                  ~key:encryption_key
                  ~nonce:(nonce "PS-Msg05")
                  ~aad:""
                  ~plaintext
              in
              let m5 =
                Tlv8.encode
                  [ Tlv8.tag_sequence_num, byte 0x05; Tlv8.tag_encrypted_data, encrypted_data ]
              in
              Ok (Awaiting_m6 { encryption_key; credentials }, m5)
            with
            | exn -> Error (Exn.to_string exn)))
  | Awaiting_m6 _ -> Error "pair-setup state is not awaiting M4"

let process_m6 state payload =
  match state with
  | Awaiting_m6 { encryption_key; credentials } ->
      let* message = decode_message payload in
      let* message = check_peer_error message in
      let* encrypted_data = find_required Tlv8.tag_encrypted_data "encrypted data" message in
      (match
         Crypto.chacha20_poly1305_decrypt
           ~key:encryption_key
           ~nonce:(nonce "PS-Msg06")
           ~aad:""
           ~ciphertext_with_tag:encrypted_data
       with
       | None -> Error "unable to decrypt M6 payload"
       | Some plaintext ->
           let* inner = decode_message plaintext in
           let* receiver_ltpk = find_required Tlv8.tag_public_key "receiver public key" inner in
           Ok { credentials with receiver_ltpk_hex = Ohex.encode receiver_ltpk })
  | Awaiting_m4 _ -> Error "pair-setup state is not awaiting M6"

(* Drives the HAP pair-setup exchange over plain HTTP. *)

let pair_setup_user_agent = "AirPlay/320.20"
let pin_start_user_agent = "MediaControl/1.0"

let setup_headers ~user_agent =
  [
    "User-Agent", user_agent;
    "X-Apple-HKP", "3";
    "Content-Type", "application/octet-stream";
    "Connection", "keep-alive";
  ]

let check_ok status path =
  match status with
  | 200 -> ()
  | code -> Printf.failwithf "%s returned HTTP %d" path code ()

let post_or_fail t ~path ~user_agent ~body =
  let status, _headers, response = Http_tcp.post t ~path ~headers:(setup_headers ~user_agent) ~body in
  check_ok status path;
  response

let result_or_fail context = function
  | Ok value -> value
  | Error message -> Printf.failwithf "%s: %s" context message ()

let setup_start ~net ~sw ~address ~port =
  Log.info (fun m -> m "pair-setup start against %s:%d" address port);
  let t = Http_tcp.connect ~net ~sw ~address ~port in
  let _ = post_or_fail t ~path:"/pair-pin-start" ~user_agent:pin_start_user_agent ~body:"" in
  t

let setup_finish t ~pin =
  Log.info (fun m -> m "pair-setup M3..M6 with pin of length %d" (String.length pin));
  let m1 = build_m1 () in
  let m2 = post_or_fail t ~path:"/pair-setup" ~user_agent:pair_setup_user_agent ~body:m1 in
  let state, m3 = result_or_fail "process_m2" (process_m2 ~password:pin m2) in
  let m4 = post_or_fail t ~path:"/pair-setup" ~user_agent:pair_setup_user_agent ~body:m3 in
  let state, m5 = result_or_fail "process_m4" (process_m4 state m4) in
  let m6 = post_or_fail t ~path:"/pair-setup" ~user_agent:pair_setup_user_agent ~body:m5 in
  let credentials = result_or_fail "process_m6" (process_m6 state m6) in
  Log.info (fun m -> m "pair-setup complete; controller_pairing_id=%s" credentials.controller_pairing_id);
  credentials

type outcome = (credentials, Err.t) Result.t

(* An in-flight pair-setup handshake. The handshake fiber blocks on a PIN
   the user reads off the receiver; [submit_pin] supplies it and awaits the
   outcome. The caller (freetube) owns any registry keyed by HTTP session. *)
type t = {
  pin_resolver : string Eio.Promise.u;
  outcome : outcome Eio.Promise.t;
}

let start ~env ~sw ~address ~port ~receiver_pairing_id =
  let net = Eio.Stdenv.net env in
  let pin_promise, pin_resolver = Eio.Promise.create () in
  let outcome_promise, outcome_resolver = Eio.Promise.create () in
  let started_promise, started_resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Result.try_with (fun () ->
        Eio.Switch.run @@ fun sw ->
        let connection = setup_start ~net ~sw ~address ~port in
        Eio.Promise.resolve started_resolver ();
        let pin = Eio.Promise.await pin_promise in
        setup_finish connection ~pin)
    in
    let outcome =
      match result with
      | Ok credentials ->
          Ok { credentials with pairing_id = receiver_pairing_id }
      | Error exn -> Error (Err.Auth_failed (Exn.to_string exn))
    in
    Eio.Promise.resolve outcome_resolver outcome;
    match Eio.Promise.is_resolved started_promise with
    | true -> ()
    | false ->
        Eio.Promise.resolve started_resolver ());
  Eio.Promise.await started_promise;
  { pin_resolver; outcome = outcome_promise }

let submit_pin t ~pin =
  Eio.Promise.resolve t.pin_resolver pin;
  Eio.Promise.await t.outcome
