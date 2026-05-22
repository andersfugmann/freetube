open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HAP pair-verify protocol" Stdlib.__MODULE__)

let ( let* ) result f = Result.bind result ~f

type session_keys = {
  encrypt_key : string;
  decrypt_key : string;
  shared_secret : string;
}

let byte value = String.of_char (Char.of_int_exn value)
let nonce label = String.make 4 '\000' ^ label

let pp_ec_error = Mirage_crypto_ec.pp_error

let unwrap_result result ~context =
  match result with
  | Ok value -> Ok value
  | Error error -> Error (context ^ ": " ^ Stdlib.Format.asprintf "%a" pp_ec_error error)

let decode_message payload =
  try Ok (Tlv8.decode payload) with
  | exn -> Error (Exn.to_string exn)

let check_peer_error message =
  match Tlv8.find Tlv8.tag_error message with
  | None -> Ok message
  | Some error_code when String.is_empty error_code -> Error "peer returned empty error TLV"
  | Some error_code ->
      Error (Stdlib.Printf.sprintf "peer returned error 0x%02x" (Char.to_int (String.get error_code 0)))

let find_required tag name message =
  match Tlv8.find tag message with
  | Some value -> Ok value
  | None -> Error (name ^ " missing from TLV")

let controller_public_of_private private_key =
    let* _secret, public_key =
    unwrap_result
      (Mirage_crypto_ec.X25519.secret_of_octets private_key)
      ~context:"invalid X25519 private key"
  in
  Ok public_key

let build_m1 () =
  let ephemeral_private, ephemeral_public = Crypto.x25519_generate_keypair () in
  let m1 =
    Tlv8.encode
      [ Tlv8.tag_sequence_num, byte 0x01; Tlv8.tag_public_key, ephemeral_public ]
  in
  ephemeral_private, m1

let process_m2 ~(credentials : Pairing.credentials) ~ephemeral_private payload =
    let* controller_ephemeral_public = controller_public_of_private ephemeral_private in
  let* message = decode_message payload in
  let* message = check_peer_error message in
  let* receiver_ephemeral_public = find_required Tlv8.tag_public_key "receiver ephemeral public key" message in
  let* encrypted_data = find_required Tlv8.tag_encrypted_data "encrypted data" message in
  try
    let shared_secret =
      Crypto.x25519_shared_secret ~private_key:ephemeral_private ~peer_public:receiver_ephemeral_public
    in
    let verify_key =
      Hkdf.derive
        ~salt:"Pair-Verify-Encrypt-Salt"
        ~info:"Pair-Verify-Encrypt-Info"
        ~length:32
        ~ikm:shared_secret
    in
    match
      Crypto.chacha20_poly1305_decrypt
        ~key:verify_key
        ~nonce:(nonce "PV-Msg02")
        ~aad:""
        ~ciphertext_with_tag:encrypted_data
    with
    | None -> Error "unable to decrypt M2 payload"
    | Some plaintext ->
        let* inner = decode_message plaintext in
        let* receiver_identifier = find_required Tlv8.tag_identifier "receiver identifier" inner in
        let* receiver_signature = find_required Tlv8.tag_signature "receiver signature" inner in
        let receiver_message =
          receiver_ephemeral_public ^ receiver_identifier ^ controller_ephemeral_public
        in
        (match
           Crypto.ed25519_verify
             ~public_key:(Pairing.receiver_ltpk credentials)
             ~message:receiver_message
             ~signature:receiver_signature
         with
         | false -> Error "receiver signature verification failed"
         | true ->
             let controller_signature =
               Crypto.ed25519_sign
                 ~private_key:(Pairing.controller_ltsk credentials)
                 ~message:
                   (controller_ephemeral_public
                    ^ Pairing.controller_pairing_id credentials
                    ^ receiver_ephemeral_public)
             in
             let m3_plaintext =
               Tlv8.encode
                 [
                   Tlv8.tag_identifier, Pairing.controller_pairing_id credentials;
                   Tlv8.tag_signature, controller_signature;
                 ]
             in
             let m3_encrypted =
               Crypto.chacha20_poly1305_encrypt
                 ~key:verify_key
                 ~nonce:(nonce "PV-Msg03")
                 ~aad:""
                 ~plaintext:m3_plaintext
             in
             let session_keys =
               {
                 encrypt_key =
                   Hkdf.derive
                     ~salt:"Control-Salt"
                     ~info:"Control-Write-Encryption-Key"
                     ~length:32
                     ~ikm:shared_secret;
                 decrypt_key =
                   Hkdf.derive
                     ~salt:"Control-Salt"
                     ~info:"Control-Read-Encryption-Key"
                     ~length:32
                     ~ikm:shared_secret;
                 shared_secret;
               }
             in
             Ok
               ( session_keys,
                 Tlv8.encode
                   [ Tlv8.tag_sequence_num, byte 0x03; Tlv8.tag_encrypted_data, m3_encrypted ]
               ))
  with
  | exn -> Error (Exn.to_string exn)

let verify_m4 payload =
    let* message = decode_message payload in
  let* message = check_peer_error message in
  match Tlv8.find Tlv8.tag_sequence_num message with
  | Some sequence when String.equal sequence (byte 0x04) -> Ok ()
  | Some _ -> Error "unexpected pair-verify sequence number"
  | None -> Error "pair-verify response missing sequence number"
