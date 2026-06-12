open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Friendly-name → ASCII filename slug" Stdlib.__MODULE__)

(* Direct UTF-8 byte-sequence rewrites for Scandinavian letters. The
   sequences below are the encoded forms of æ Æ ø Ø å Å. *)
let scandi_rewrites = [
  "\xc3\xa6", "ae"; "\xc3\x86", "ae";
  "\xc3\xb8", "oe"; "\xc3\x98", "oe";
  "\xc3\xa5", "aa"; "\xc3\x85", "aa";
]

let fallback_slug source =
  let hash =
    String.fold source ~init:5381 ~f:(fun acc c ->
      ((acc lsl 5) + acc + Char.to_int c) land 0xFFFFFF)
  in
  Printf.sprintf "device_%06x" hash

let of_friendly_name name =
  let rewritten =
    List.fold scandi_rewrites ~init:name ~f:(fun acc (from_, to_) ->
      String.substr_replace_all acc ~pattern:from_ ~with_:to_)
  in
  let slug =
    rewritten
    |> String.lowercase
    |> String.to_list
    |> List.map ~f:(fun c ->
      match Char.between c ~low:'a' ~high:'z'
          || Char.between c ~low:'0' ~high:'9' with
      | true -> c
      | false -> '_')
    |> String.of_char_list
  in
  let slug =
    String.split slug ~on:'_'
    |> List.filter ~f:(fun s -> not (String.is_empty s))
    |> String.concat ~sep:"_"
  in
  match String.is_empty slug with
  | true -> fallback_slug rewritten
  | false -> slug

let%expect_test "scandi" =
  Stdlib.print_endline (of_friendly_name "Stueøret Æg på Åbo");
  [%expect {| stueoeret_aeg_paa_aabo |}]

let%expect_test "spaces and slashes" =
  Stdlib.print_endline (of_friendly_name "Living Room / TV");
  [%expect {| living_room_tv |}]

let%expect_test "all-symbols collapse" =
  Stdlib.print_endline (of_friendly_name "!!@@##");
  [%expect {| device_52974d |}]

let%expect_test "trim leading underscore" =
  Stdlib.print_endline (of_friendly_name " Hello ");
  [%expect {| hello |}]
