open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay cryptographic primitives" Stdlib.__MODULE__)

let pp_ec_error = Mirage_crypto_ec.pp_error

let unwrap_result result ~context ~pp_error =
  match result with
  | Ok value -> value
  | Error error ->
      failwith
        (Stdlib.Printf.sprintf "%s: %s" context (Stdlib.Format.asprintf "%a" pp_error error))

let sha512 message = Digestif.SHA512.digest_string message |> Digestif.SHA512.to_raw_string

let chacha20_poly1305_encrypt ~key ~nonce ~aad ~plaintext =
  let key = Mirage_crypto.Chacha20.of_secret key in
  Mirage_crypto.Chacha20.authenticate_encrypt ~key ~nonce ~adata:aad plaintext

let chacha20_poly1305_decrypt ~key ~nonce ~aad ~ciphertext_with_tag =
  let key = Mirage_crypto.Chacha20.of_secret key in
  Mirage_crypto.Chacha20.authenticate_decrypt ~key ~nonce ~adata:aad ciphertext_with_tag

let ed25519_sign ~private_key ~message =
  let private_key =
    unwrap_result
      (Mirage_crypto_ec.Ed25519.priv_of_octets private_key)
      ~context:"invalid Ed25519 private key"
      ~pp_error:pp_ec_error
  in
  Mirage_crypto_ec.Ed25519.sign ~key:private_key message

let ed25519_verify ~public_key ~message ~signature =
  let public_key =
    unwrap_result
      (Mirage_crypto_ec.Ed25519.pub_of_octets public_key)
      ~context:"invalid Ed25519 public key"
      ~pp_error:pp_ec_error
  in
  Mirage_crypto_ec.Ed25519.verify ~key:public_key signature ~msg:message

let x25519_generate_keypair () =
  let private_key, public_key = Mirage_crypto_ec.X25519.gen_key () in
  Mirage_crypto_ec.X25519.secret_to_octets private_key, public_key

let x25519_shared_secret ~private_key ~peer_public =
  let private_key, _public_key =
    unwrap_result
      (Mirage_crypto_ec.X25519.secret_of_octets private_key)
      ~context:"invalid X25519 private key"
      ~pp_error:pp_ec_error
  in
  unwrap_result
    (Mirage_crypto_ec.X25519.key_exchange private_key peer_public)
    ~context:"invalid X25519 peer public key"
    ~pp_error:pp_ec_error
