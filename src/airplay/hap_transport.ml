open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Encrypted HAP transport" Stdlib.__MODULE__)

type t = {
  encrypt_key : string;
  decrypt_key : string;
  mutable encrypt_nonce : int64;
  mutable decrypt_nonce : int64;
}

let create ~(session_keys : Pair_verify.session_keys) =
  {
    encrypt_key = session_keys.encrypt_key;
    decrypt_key = session_keys.decrypt_key;
    encrypt_nonce = 0L;
    decrypt_nonce = 0L;
  }

let le_uint16 value =
  match Int.between value ~low:0 ~high:0xffff with
  | false -> failwith (Stdlib.Printf.sprintf "Frame length out of range: %d" value)
  | true ->
      String.of_char_list
        [ Char.of_int_exn (value land 0xff); Char.of_int_exn ((value lsr 8) land 0xff) ]

let uint16_of_le value =
  (Char.to_int (String.get value 0)) lor ((Char.to_int (String.get value 1)) lsl 8)

let nonce_of_counter counter =
  let nonce = Bytes.make 12 '\000' in
  let byte_at shift =
    Stdlib.Int64.(to_int (logand (shift_right_logical counter shift) 0xffL))
  in
  List.iter [ 0; 8; 16; 24; 32; 40; 48; 56 ] ~f:(fun shift ->
    Bytes.set nonce ((shift / 8) + 4) (Char.of_int_exn (byte_at shift)));
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:nonce

let encrypt_frame transport plaintext =
  let aad = le_uint16 (String.length plaintext) in
  let nonce = nonce_of_counter transport.encrypt_nonce in
  transport.encrypt_nonce <- Int64.succ transport.encrypt_nonce;
  let ciphertext =
    Crypto.chacha20_poly1305_encrypt ~key:transport.encrypt_key ~nonce ~aad ~plaintext
  in
  aad ^ ciphertext

let decrypt_frame transport frame =
  match String.length frame >= 2 with
  | false -> None
  | true ->
      let aad = String.sub frame ~pos:0 ~len:2 in
      let plaintext_length = uint16_of_le aad in
      let expected_length = 2 + plaintext_length + 16 in
      match Int.equal (String.length frame) expected_length with
      | false -> None
      | true ->
          let ciphertext_with_tag = String.drop_prefix frame 2 in
          let nonce = nonce_of_counter transport.decrypt_nonce in
          transport.decrypt_nonce <- Int64.succ transport.decrypt_nonce;
          Crypto.chacha20_poly1305_decrypt
            ~key:transport.decrypt_key
            ~nonce
            ~aad
            ~ciphertext_with_tag
