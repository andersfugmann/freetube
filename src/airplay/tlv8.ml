open! Base
open Util

module Log = (val Log_src.src_log ~doc:"TLV8 codec" Stdlib.__MODULE__)

type t = (int * string) list

let tag_method = 0x00
let tag_identifier = 0x01
let tag_salt = 0x02
let tag_public_key = 0x03
let tag_proof = 0x04
let tag_encrypted_data = 0x05
let tag_sequence_num = 0x06
let tag_error = 0x07
let tag_signature = 0x0a

let char_of_u8_exn value =
  match Int.between value ~low:0 ~high:255 with
  | true -> Char.of_int_exn value
  | false -> failwith (Stdlib.Printf.sprintf "TLV8 byte out of range: %d" value)

let encode_record tag value =
  String.of_char_list
    [ char_of_u8_exn tag; char_of_u8_exn (String.length value) ]
  ^ value

let rec encode_fragments tag value ~pos =
  match String.length value - pos with
  | 0 when Int.equal pos 0 -> [ encode_record tag "" ]
  | 0 -> []
  | remaining ->
      let len = Int.min 255 remaining in
      let fragment = String.sub value ~pos ~len in
      encode_record tag fragment :: encode_fragments tag value ~pos:(pos + len)

let encode entries =
  entries
  |> List.concat_map ~f:(fun (tag, value) -> encode_fragments tag value ~pos:0)
  |> String.concat

let decode input =
  let flush current_tag current_value acc =
    match current_tag with
    | None -> acc
    | Some tag -> (tag, current_value) :: acc
  in
  let rec loop pos current_tag current_value acc =
    match Int.equal pos (String.length input) with
    | true -> flush current_tag current_value acc |> List.rev
    | false ->
        let remaining = String.length input - pos in
        match remaining >= 2 with
        | false -> failwith "TLV8 truncated header"
        | true ->
            let tag = Char.to_int (String.get input pos) in
            let len = Char.to_int (String.get input (pos + 1)) in
            let value_pos = pos + 2 in
            match String.length input - value_pos >= len with
            | false -> failwith "TLV8 truncated value"
            | true ->
                let value = String.sub input ~pos:value_pos ~len in
                let next_pos = value_pos + len in
                (match current_tag with
                 | Some current when Int.equal current tag ->
                     loop next_pos current_tag (current_value ^ value) acc
                 | _ ->
                     let acc = flush current_tag current_value acc in
                     loop next_pos (Some tag) value acc)
  in
  loop 0 None "" []

let find tag entries =
  entries
  |> List.find_map ~f:(fun (entry_tag, value) ->
    match Int.equal entry_tag tag with
    | true -> Some value
    | false -> None)

let find_exn tag entries =
  match find tag entries with
  | Some value -> value
  | None -> failwith (Stdlib.Printf.sprintf "TLV8 tag 0x%02x not found" tag)

let%test "roundtrip preserves pairs" =
  let entries =
    [ tag_method, "\x00"; tag_sequence_num, "\x01"; tag_identifier, "controller" ]
  in
  Poly.equal (decode (encode entries)) entries

let%test "fragments values larger than 255 bytes" =
  let value =
    String.init 300 ~f:(fun index -> Char.of_int_exn (((index % 26)) + Char.to_int 'a'))
  in
  let encoded = encode [ tag_public_key, value ] in
  let first_tag = Char.to_int (String.get encoded 0) in
  let first_len = Char.to_int (String.get encoded 1) in
  let second_tag = Char.to_int (String.get encoded 257) in
  let second_len = Char.to_int (String.get encoded 258) in
  Int.equal first_tag tag_public_key
  && Int.equal first_len 255
  && Int.equal second_tag tag_public_key
  && Int.equal second_len 45
  && Poly.equal (decode encoded) [ tag_public_key, value ]
