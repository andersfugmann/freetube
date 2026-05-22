open! Base
open Util

module Log = (val Log_src.src_log ~doc:"RFC 6381 codec string generation" Stdlib.__MODULE__)

type codec_config =
  | Avc of string
  | Hevc of string
  | Av1 of string
  | Vp9 of string
  | Aac of string
  | Opus

let get_u8 s pos = Char.to_int (String.get s pos)

let get_u32_be s pos =
  let b0 = get_u8 s pos in
  let b1 = get_u8 s (pos + 1) in
  let b2 = get_u8 s (pos + 2) in
  let b3 = get_u8 s (pos + 3) in
  (b0 lsl 24) lor (b1 lsl 16) lor (b2 lsl 8) lor b3

let require_bytes codec bytes needed =
  match String.length bytes < needed with
  | true ->
      invalid_arg
        (Stdlib.Printf.sprintf
           "container.codec_string: %s requires at least %d bytes"
           codec needed)
  | false -> ()

let profile_space_prefix = function
  | 0 -> ""
  | 1 -> "A"
  | 2 -> "B"
  | _ -> "C"

let av1_bit_depth bits =
  let high_bitdepth = (bits lsr 6) land 0x1 in
  let twelve_bit = (bits lsr 5) land 0x1 in
  match high_bitdepth, twelve_bit with
  | 0, _ -> 8
  | 1, 0 -> 10
  | _ -> 12

let to_string = function
  | Avc bytes ->
      let () = require_bytes "avcC" bytes 4 in
      Stdlib.Printf.sprintf
        "avc1.%02X%02X%02X"
        (get_u8 bytes 1)
        (get_u8 bytes 2)
        (get_u8 bytes 3)
  | Hevc bytes ->
      let () = require_bytes "hvcC" bytes 13 in
      let profile_byte = get_u8 bytes 1 in
      let profile_space = profile_space_prefix ((profile_byte lsr 6) land 0x3) in
      let profile_idc = profile_byte land 0x1F in
      let tier =
        match (profile_byte lsr 5) land 0x1 with
        | 0 -> 'L'
        | _ -> 'H'
      in
      let compat_flags = get_u32_be bytes 2 in
      let level_idc = get_u8 bytes 12 in
      Stdlib.Printf.sprintf
        "hev1.%s%d.%08X.%c%d"
        profile_space
        profile_idc
        compat_flags
        tier
        level_idc
  | Av1 bytes ->
      let () = require_bytes "av1C" bytes 3 in
      let seq_profile = (get_u8 bytes 1 lsr 5) land 0x7 in
      let seq_level_idx = get_u8 bytes 1 land 0x1F in
      let features = get_u8 bytes 2 in
      let tier =
        match (features lsr 7) land 0x1 with
        | 0 -> 'M'
        | _ -> 'H'
      in
      Stdlib.Printf.sprintf
        "av01.%d.%02d%c.%02d"
        seq_profile
        seq_level_idx
        tier
        (av1_bit_depth features)
  | Vp9 bytes ->
      let () = require_bytes "vpcC" bytes 7 in
      let profile = get_u8 bytes 4 in
      let level = get_u8 bytes 5 in
      let bit_depth = (get_u8 bytes 6 lsr 4) land 0xF in
      Stdlib.Printf.sprintf "vp09.%02d.%02d.%02d" profile level bit_depth
  | Aac _ -> "mp4a.40.2"
  | Opus -> "opus"

let%expect_test "to_string renders an AVC codec string" =
  Stdlib.Printf.printf "%s\n" (to_string (Avc "\001\100\000\040"));
  [%expect {| avc1.640028 |}]
