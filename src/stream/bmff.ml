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

let find_box_exn s ~box_type ~pos ~limit =
  find_box s ~box_type ~pos ~limit
  |> Option.value_exn ~message:(Printf.sprintf "bmff: no %s box" box_type)

(* Locate moof/traf and the named child box within the first fragment. *)
let find_in_traf s ~box_type =
  let limit = String.length s in
  let moof = find_box_exn s ~box_type:"moof" ~pos:0 ~limit in
  let traf =
    find_box_exn s ~box_type:"traf"
      ~pos:(moof.offset + moof.header_size) ~limit:(moof.size - moof.header_size)
  in
  find_box_exn s ~box_type
    ~pos:(traf.offset + traf.header_size) ~limit:(traf.size - traf.header_size)

(* Parse a trun box: (flags, sample_count, durations, sizes). Only the present
   fields are read; absent ones default to 0. *)
let parse_trun s (trun : box_header) =
  let body = trun.offset + trun.header_size in
  let flags =
    (get_u8 s (body + 1) lsl 16) lor (get_u8 s (body + 2) lsl 8) lor get_u8 s (body + 3)
  in
  let count = get_u32_be s (body + 4) in
  let p = ref (body + 8) in
  let take present =
    match present with
    | false -> None
    | true -> let v = get_u32_be s !p in p := !p + 4; Some v
  in
  ignore (take (flags land 0x1 <> 0));   (* data_offset *)
  ignore (take (flags land 0x4 <> 0));   (* first_sample_flags *)
  let durations = Array.create ~len:count 0 in
  let sizes = Array.create ~len:count 0 in
  for i = 0 to count - 1 do
    Option.iter (take (flags land 0x100 <> 0)) ~f:(fun v -> durations.(i) <- v);
    Option.iter (take (flags land 0x200 <> 0)) ~f:(fun v -> sizes.(i) <- v);
    ignore (take (flags land 0x400 <> 0));
    ignore (take (flags land 0x800 <> 0))
  done;
  (flags, count, durations, sizes)

let sum_trun_durations s =
  let _, _, durations, _ = parse_trun s (find_in_traf s ~box_type:"trun") in
  Array.fold durations ~init:0 ~f:( + )

(* Zero the PreSkip field in the Opus dOps box of an init segment so that a
   per-segment transcode does not re-apply the stream-start encoder delay. *)
let zero_opus_preskip init =
  match String.substr_index init ~pattern:"dOps" with
  | None -> init
  | Some i ->
    let buf = Bytes.of_string init in
    put_u32_be buf (i + 4) (get_u32_be init (i + 4) land 0xFFFF0000);
    Bytes.to_string buf

(* AAC-LC always decodes exactly 1024 samples per frame; the native ffmpeg
   "aac" encoder prepends exactly one such frame of priming (pure silence). *)
let aac_frame_samples = 1024

(* Rewrite a freshly transcoded AAC fragment so its declared timeline mirrors
   the source segment exactly: strip the leading priming frame, set the trun
   durations to sum to [target] samples, set [tfdt], and recompute the trun
   data_offset together with the trun/traf/moof/mdat box sizes. *)
let fixup_aac_fragment segment ~target ~tfdt:tfdt_value =
  let ( let* ) x f = Result.bind x ~f in
  let limit = String.length segment in
  let find ~box_type ~pos ~limit =
    find_box segment ~box_type ~pos ~limit
    |> Result.of_option ~error:(Printf.sprintf "bmff: no %s box" box_type)
  in
  let* moof = find ~box_type:"moof" ~pos:0 ~limit in
  let* traf =
    find ~box_type:"traf"
      ~pos:(moof.offset + moof.header_size) ~limit:(moof.size - moof.header_size)
  in
  let* tfdt =
    find ~box_type:"tfdt"
      ~pos:(traf.offset + traf.header_size) ~limit:(traf.size - traf.header_size)
  in
  let* trun =
    find ~box_type:"trun"
      ~pos:(traf.offset + traf.header_size) ~limit:(traf.size - traf.header_size)
  in
  let* mdat = find ~box_type:"mdat" ~pos:0 ~limit in
  let flags, count, _, sizes = parse_trun segment trun in
  let* () =
    match
      flags land 0x305 = 0x301,
      trun.offset + trun.size = traf.offset + traf.size,
      traf.offset + traf.size = moof.offset + moof.size,
      mdat.offset = moof.offset + moof.size
    with
    | true, true, true, true -> Ok ()
    | _ -> Error "bmff: unexpected AAC fragment layout for fixup"
  in
  let priming_bytes = sizes.(0) in
  let new_count = count - 1 in
  let new_durations =
    Array.init new_count ~f:(fun i ->
      match i = new_count - 1 with
      | false -> aac_frame_samples
      | true -> target - (aac_frame_samples * (new_count - 1)))
  in
  let new_sizes = Array.sub sizes ~pos:1 ~len:new_count in
  (* moof shrinks by exactly one per-sample entry (duration + size = 8 bytes). *)
  let new_moof_size = moof.size - 8 in
  let data_offset = new_moof_size + mdat.header_size in
  (* Build the new trun box (version 1, flags 0x000301). *)
  let trun_size = 8 + 4 + 4 + 4 + (new_count * 8) in
  let new_trun = Bytes.create trun_size in
  put_u32_be new_trun 0 trun_size;
  Bytes.From_string.blit ~src:"trun" ~src_pos:0 ~dst:new_trun ~dst_pos:4 ~len:4;
  Bytes.set new_trun 8 '\001';
  Bytes.set new_trun 9 '\000';
  Bytes.set new_trun 10 '\003';
  Bytes.set new_trun 11 '\001';
  put_u32_be new_trun 12 new_count;
  put_u32_be new_trun 16 data_offset;
  Array.iteri new_durations ~f:(fun i d ->
    let off = 20 + (i * 8) in
    put_u32_be new_trun off d;
    put_u32_be new_trun (off + 4) new_sizes.(i));
  let new_trun = Bytes.to_string new_trun in
  (* traf prefix = tfhd + tfdt + anything before trun, with tfdt value rewritten. *)
  let traf_prefix_len = trun.offset - traf.offset in
  let traf_prefix = Bytes.of_string (String.sub segment ~pos:traf.offset ~len:traf_prefix_len) in
  let tfdt_version = get_u8 segment (tfdt.offset + tfdt.header_size) in
  let tfdt_value_pos = (tfdt.offset - traf.offset) + tfdt.header_size + 4 in
  (match tfdt_version with
   | 0 -> put_u32_be traf_prefix tfdt_value_pos (Int64.to_int_exn tfdt_value)
   | _ -> put_u64_be traf_prefix tfdt_value_pos tfdt_value);
  let new_traf_size = traf_prefix_len + String.length new_trun in
  put_u32_be traf_prefix 0 new_traf_size;
  let new_traf = Bytes.to_string traf_prefix ^ new_trun in
  (* moof prefix = moof header + mfhd (everything before traf). *)
  let moof_prefix = Bytes.of_string (String.sub segment ~pos:moof.offset ~len:(traf.offset - moof.offset)) in
  put_u32_be moof_prefix 0 new_moof_size;
  let new_moof = Bytes.to_string moof_prefix ^ new_traf in
  (* mdat without the priming frame's bytes. *)
  let mdat_payload_pos = mdat.offset + mdat.header_size + priming_bytes in
  let mdat_payload_len = mdat.size - mdat.header_size - priming_bytes in
  let new_mdat = Bytes.create mdat.header_size in
  put_u32_be new_mdat 0 (mdat.header_size + mdat_payload_len);
  Bytes.From_string.blit ~src:"mdat" ~src_pos:0 ~dst:new_mdat ~dst_pos:4 ~len:4;
  String.concat
    [ String.sub segment ~pos:0 ~len:moof.offset;
      new_moof;
      Bytes.to_string new_mdat;
      String.sub segment ~pos:mdat_payload_pos ~len:mdat_payload_len ]
  |> Result.return

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


