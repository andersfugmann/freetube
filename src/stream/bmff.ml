open! Base
open Util

module Log = (val Log_src.src_log ~doc:"ISO BMFF container parsing" Stdlib.__MODULE__)

type box_header = {
  box_type : string;
  offset : int;
  size : int;
  header_size : int;
}

type sidx_entry = {
  reference_type : int;
  referenced_size : int;
  subsegment_duration : int;
  starts_with_sap : bool;
  sap_type : int;
}

type sidx = {
  timescale : int;
  earliest_presentation_time : int;
  first_offset : int;
  entries : sidx_entry list;
}

type segment_range = {
  offset : int;
  length : int;
  duration_ticks : int;
  timescale : int;
}

let invalid_range s ~pos ~len =
  invalid_arg
    (Stdlib.Printf.sprintf
       "container.bmff: invalid range pos=%d len=%d input=%d"
       pos len (String.length s))

let check_range s ~pos ~len =
  match pos < 0 || len < 0 || pos + len > String.length s with
  | true -> invalid_range s ~pos ~len
  | false -> ()

let get_u8 s pos = Char.to_int (String.get s pos)

let get_u16_be s pos =
  let b0 = get_u8 s pos in
  let b1 = get_u8 s (pos + 1) in
  (b0 lsl 8) lor b1

let get_u32_be s pos =
  let b0 = get_u8 s pos in
  let b1 = get_u8 s (pos + 1) in
  let b2 = get_u8 s (pos + 2) in
  let b3 = get_u8 s (pos + 3) in
  (b0 lsl 24) lor (b1 lsl 16) lor (b2 lsl 8) lor b3

let get_u64_be s pos =
  let hi = Int64.of_int (get_u32_be s pos) in
  let lo = Int64.of_int (get_u32_be s (pos + 4)) in
  Stdlib.Int64.logor (Stdlib.Int64.shift_left hi 32) lo |> Int64.to_int_exn

let validate_box_size ~box_type ~size ~header_size =
  match size < header_size with
  | true ->
      invalid_arg
        (Stdlib.Printf.sprintf
           "container.bmff: box %s has invalid size %d"
           box_type size)
  | false -> size

let parse_box_header s ~pos =
  check_range s ~pos ~len:8;
  let size32 = get_u32_be s pos in
  let box_type = String.sub s ~pos:(pos + 4) ~len:4 in
  match size32 with
  | 0 ->
      {
        box_type;
        offset = pos;
        size = validate_box_size ~box_type ~size:(String.length s - pos) ~header_size:8;
        header_size = 8;
      }
  | 1 ->
      check_range s ~pos:(pos + 8) ~len:8;
      let size = get_u64_be s (pos + 8) in
      {
        box_type;
        offset = pos;
        size = validate_box_size ~box_type ~size ~header_size:16;
        header_size = 16;
      }
  | size ->
      { box_type; offset = pos; size = validate_box_size ~box_type ~size ~header_size:8; header_size = 8 }

let find_box s ~box_type ~pos ~limit =
  let end_pos = Int.min (String.length s) (pos + limit) in
  let rec loop current =
    match current < pos || current + 8 > end_pos with
    | true -> None
    | false ->
        let header = parse_box_header s ~pos:current in
        let next_pos = current + header.size in
        (match String.equal header.box_type box_type, next_pos > end_pos, header.size <= 0 with
        | true, false, false -> Some header
        | _, true, _ | _, _, true -> None
        | false, false, false -> loop next_pos)
  in
  match pos < 0 || limit < 0 with
  | true -> invalid_arg "container.bmff: invalid scan range"
  | false -> loop pos

let parse_sidx s ~pos =
  let header = parse_box_header s ~pos in
  let () = check_range s ~pos ~len:header.size in
  match header.box_type with
  | "sidx" ->
      let full_box_pos = pos + header.header_size in
      let () = check_range s ~pos:full_box_pos ~len:4 in
      let version = get_u8 s full_box_pos in
      let body_pos = full_box_pos + 4 in
      let timescale = get_u32_be s (body_pos + 4) in
      let earliest_presentation_time, first_offset, entries_pos =
        match version with
        | 0 ->
            ( get_u32_be s (body_pos + 8)
            , get_u32_be s (body_pos + 12)
            , body_pos + 20 )
        | 1 ->
            ( get_u64_be s (body_pos + 8)
            , get_u64_be s (body_pos + 16)
            , body_pos + 28 )
        | _ ->
            invalid_arg
              (Stdlib.Printf.sprintf
                 "container.bmff: unsupported sidx version %d"
                 version)
      in
      let reference_count = get_u16_be s (entries_pos - 2) in
      let () = check_range s ~pos:entries_pos ~len:(reference_count * 12) in
      let rec parse_entries index entry_pos acc =
        match index = reference_count with
        | true -> List.rev acc
        | false ->
            let reference_word = get_u32_be s entry_pos in
            let sap_word = get_u32_be s (entry_pos + 8) in
            let entry =
              {
                reference_type = reference_word lsr 31;
                referenced_size = reference_word land 0x7FFF_FFFF;
                subsegment_duration = get_u32_be s (entry_pos + 4);
                starts_with_sap = ((sap_word lsr 31) land 0x1) = 1;
                sap_type = (sap_word lsr 28) land 0x7;
              }
            in
            parse_entries (index + 1) (entry_pos + 12) (entry :: acc)
      in
      {
        timescale;
        earliest_presentation_time;
        first_offset;
        entries = parse_entries 0 entries_pos [];
      }
  | _ -> invalid_arg "container.bmff: expected sidx box"

let segment_ranges sidx ~base_offset =
  let initial_offset = base_offset + sidx.first_offset in
  List.fold sidx.entries ~init:(initial_offset, []) ~f:(fun (offset, acc) entry ->
      let next_offset = offset + entry.referenced_size in
      match entry.reference_type with
      | 0 ->
          ( next_offset
          , {
              offset;
              length = entry.referenced_size;
              duration_ticks = entry.subsegment_duration;
              timescale = sidx.timescale;
            }
            :: acc )
      | _ -> next_offset, acc)
  |> snd |> List.rev

let split_init_and_segments s =
  let limit = String.length s in
  let moov =
    find_box s ~box_type:"moov" ~pos:0 ~limit
    |> Option.value_exn ~message:"container.bmff: missing moov box"
  in
  let init_segment = String.sub s ~pos:0 ~len:(moov.offset + moov.size) in
  let scan_start = moov.offset + moov.size in
  let rec collect pos acc =
    match pos >= limit with
    | true -> List.rev acc
    | false ->
        match find_box s ~box_type:"sidx" ~pos ~limit:(limit - pos) with
        | None -> List.rev acc
        | Some sidx_box ->
            let sidx = parse_sidx s ~pos:sidx_box.offset in
            let base = sidx_box.offset + sidx_box.size in
            let ranges = segment_ranges sidx ~base_offset:base in
            let next_pos =
              List.fold ranges ~init:base ~f:(fun off (r : segment_range) ->
                Int.max off (r.offset + r.length))
            in
            collect next_pos (List.rev_append ranges acc)
  in
  let ranges =
    match collect scan_start [] with
    | [] ->
        (* fallback: legacy files with sidx before moov *)
        (match find_box s ~box_type:"sidx" ~pos:0 ~limit with
         | Some sidx_box ->
             let sidx = parse_sidx s ~pos:sidx_box.offset in
             segment_ranges sidx ~base_offset:(sidx_box.offset + sidx_box.size)
         | None ->
             invalid_arg "container.bmff: missing sidx box")
    | rs -> rs
  in
  init_segment, ranges

type brand = Iso5 | Isom [@@deriving yojson]

let brand_fourcc = function
  | Iso5 -> "iso5"
  | Isom -> "isom"

let set_major_brand s ~brand =
  let fourcc = brand_fourcc brand in
  let header = parse_box_header s ~pos:0 in
  let () =
    match header.box_type with
    | "ftyp" | "styp" -> ()
    | other ->
        invalid_arg
          (Stdlib.Printf.sprintf
             "container.bmff: expected ftyp or styp at offset 0, got %s" other)
  in
  let brand_pos = header.offset + header.header_size in
  let buf = Bytes.of_string s in
  Bytes.From_string.blit ~src:fourcc ~src_pos:0 ~dst:buf ~dst_pos:brand_pos ~len:4;
  Bytes.to_string buf

let put_u32_be buf pos v =
  Bytes.set buf pos (Char.of_int_exn ((v lsr 24) land 0xFF));
  Bytes.set buf (pos + 1) (Char.of_int_exn ((v lsr 16) land 0xFF));
  Bytes.set buf (pos + 2) (Char.of_int_exn ((v lsr 8) land 0xFF));
  Bytes.set buf (pos + 3) (Char.of_int_exn (v land 0xFF))

let put_u64_be buf pos v =
  for i = 0 to 7 do
    let byte = Int64.to_int_exn (Int64.( land ) (Int64.shift_right_logical v ((7 - i) * 8)) 0xFFL) in
    Bytes.set buf (pos + i) (Char.of_int_exn byte)
  done

let find_tfdt s =
  let limit = String.length s in
  let moof =
    find_box s ~box_type:"moof" ~pos:0 ~limit
    |> Option.value_exn ~message:"bmff: no moof box"
  in
  let moof_body = moof.offset + moof.header_size in
  let moof_end = moof.offset + moof.size in
  let traf =
    find_box s ~box_type:"traf" ~pos:moof_body ~limit:(moof_end - moof_body)
    |> Option.value_exn ~message:"bmff: no traf box in moof"
  in
  let traf_body = traf.offset + traf.header_size in
  let traf_end = traf.offset + traf.size in
  find_box s ~box_type:"tfdt" ~pos:traf_body ~limit:(traf_end - traf_body)
  |> Option.value_exn ~message:"bmff: no tfdt box in traf"

let read_tfdt_value s (tfdt : box_header) =
  let full_box_pos = tfdt.offset + tfdt.header_size in
  let version = get_u8 s full_box_pos in
  let value_pos = full_box_pos + 4 in
  match version with
  | 0 -> Int64.of_int (get_u32_be s value_pos)
  | _ ->
    let hi = Int64.of_int (get_u32_be s value_pos) in
    let lo = Int64.of_int (get_u32_be s (value_pos + 4)) in
    Int64.(shift_left hi 32 lor lo)

let write_tfdt_value buf s (tfdt : box_header) value =
  let full_box_pos = tfdt.offset + tfdt.header_size in
  let version = get_u8 s full_box_pos in
  let value_pos = full_box_pos + 4 in
  match version with
  | 0 -> put_u32_be buf value_pos (Int64.to_int_exn value)
  | _ -> put_u64_be buf value_pos value

let get_base_media_decode_time s =
  read_tfdt_value s (find_tfdt s)

let shift_base_media_decode_times s ~offset =
  let limit = String.length s in
  let buf = Bytes.of_string s in
  let rec loop pos =
    match find_box s ~box_type:"moof" ~pos ~limit:(limit - pos) with
    | None -> ()
    | Some moof ->
      let moof_body = moof.offset + moof.header_size in
      let moof_end = moof.offset + moof.size in
      (match find_box s ~box_type:"traf" ~pos:moof_body ~limit:(moof_end - moof_body) with
       | None -> ()
       | Some traf ->
         let traf_body = traf.offset + traf.header_size in
         let traf_end = traf.offset + traf.size in
         (match find_box s ~box_type:"tfdt" ~pos:traf_body ~limit:(traf_end - traf_body) with
          | None -> ()
          | Some tfdt ->
            let current = read_tfdt_value s tfdt in
            write_tfdt_value buf s tfdt Int64.(current + offset)));
      loop (moof.offset + moof.size)
  in
  loop 0;
  Bytes.to_string buf

let mdhd_timescale s =
  let limit = String.length s in
  let moov =
    find_box s ~box_type:"moov" ~pos:0 ~limit
    |> Option.value_exn ~message:"bmff: no moov box"
  in
  let moov_body = moov.offset + moov.header_size in
  let moov_end = moov.offset + moov.size in
  let trak =
    find_box s ~box_type:"trak" ~pos:moov_body ~limit:(moov_end - moov_body)
    |> Option.value_exn ~message:"bmff: no trak box"
  in
  let trak_body = trak.offset + trak.header_size in
  let trak_end = trak.offset + trak.size in
  let mdia =
    find_box s ~box_type:"mdia" ~pos:trak_body ~limit:(trak_end - trak_body)
    |> Option.value_exn ~message:"bmff: no mdia box"
  in
  let mdia_body = mdia.offset + mdia.header_size in
  let mdia_end = mdia.offset + mdia.size in
  let mdhd =
    find_box s ~box_type:"mdhd" ~pos:mdia_body ~limit:(mdia_end - mdia_body)
    |> Option.value_exn ~message:"bmff: no mdhd box"
  in
  let full_box_pos = mdhd.offset + mdhd.header_size in
  let version = get_u8 s full_box_pos in
  match version with
  | 0 -> get_u32_be s (full_box_pos + 4 + 8)
  | _ -> get_u32_be s (full_box_pos + 4 + 16)

let%expect_test "set_major_brand replaces ftyp major brand" =
  let segment = "\000\000\000\016ftypiso5\000\000\000\000" in
  let patched = set_major_brand segment ~brand:Isom in
  Stdlib.Printf.printf "%s\n" (String.sub patched ~pos:8 ~len:4);
  [%expect {| isom |}]

let%expect_test "set_major_brand replaces styp major brand" =
  let segment = "\000\000\000\016stypmsdh\000\000\000\000" in
  let patched = set_major_brand segment ~brand:Isom in
  Stdlib.Printf.printf "%s\n" (String.sub patched ~pos:8 ~len:4);
  [%expect {| isom |}]

let%expect_test "parse_box_header parses a standard header" =
  let header = parse_box_header "\000\000\000\024moov" ~pos:0 in
  Stdlib.Printf.printf "%s %d %d %d\n" header.box_type header.offset header.size header.header_size;
  [%expect {| moov 0 24 8 |}]


