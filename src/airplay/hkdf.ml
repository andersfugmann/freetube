open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HKDF-SHA512 key derivation" Stdlib.__MODULE__)

let hash_len = 64

let hmac_sha512 ~key data =
  Digestif.SHA512.hmac_string ~key data |> Digestif.SHA512.to_raw_string

let derive ~salt ~info ~length ~ikm =
  match length <= hash_len * 255 with
  | false -> failwith "HKDF output length exceeds RFC 5869 limit"
  | true ->
      let extract_salt =
        match String.is_empty salt with
        | true -> String.make hash_len '\000'
        | false -> salt
      in
      let prk = hmac_sha512 ~key:extract_salt ikm in
      let rec expand counter previous acc produced =
        match produced >= length with
        | true -> acc |> List.rev |> String.concat |> fun value -> String.prefix value length
        | false ->
            let block =
              hmac_sha512 ~key:prk (previous ^ info ^ String.of_char (Char.of_int_exn counter))
            in
            expand (counter + 1) block (block :: acc) (produced + String.length block)
      in
      expand 1 "" [] 0

let%test "matches hkdf-sha512 test vector" =
  let ikm = String.make 22 (Char.of_int_exn 0x0b) in
  let salt = Ohex.decode "000102030405060708090a0b0c" in
  let info = Ohex.decode "f0f1f2f3f4f5f6f7f8f9" in
  let expected = "832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c1481579338da362cb8d9f925d7cb" in
  derive ~salt ~info ~length:42 ~ikm |> Ohex.encode |> String.equal expected
