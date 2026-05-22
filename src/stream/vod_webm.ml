
open! Base
open Util

(** YouTube VOD fetcher for WebM (VP9 video, Opus audio). Reads EBML +
    SeekHead from a small prefix GET (total length comes from its
    Content-Range), then exact bounded GETs for Info, Tracks, and Cues. *)

module Log = (val Log_src.src_log ~doc:"YouTube VOD WebM fetch" Stdlib.__MODULE__)

let head_probe_size = 16 * 1024
let element_probe_size = 4 * 1024

let webm_info init_bytes =
  let length = String.length init_bytes in
  let result =
    let ( let* ) x f = Option.bind x ~f in
    let* seg =
      Ebml.find_element init_bytes ~id:Ebml.segment_id ~pos:0 ~limit:length
    in
    let* info =
      Ebml.find_element init_bytes ~id:Ebml.info_id
        ~pos:(seg.offset + seg.header_size) ~limit:seg.data_size
    in
    Some (Ebml.parse_segment_info init_bytes
            ~pos:(info.offset + info.header_size) ~limit:info.data_size)
  in
  Option.value result ~default:(1_000_000, None)

let read_bytes ~client ~url ~headers ~head_buf ~offset ~len =
  match offset + len <= String.length head_buf with
  | true -> String.sub head_buf ~pos:offset ~len
  | false ->
      let range =
        Stdlib.Printf.sprintf "bytes=%d-%d" offset (offset + len - 1)
      in
      let body, _ =
        Http_range.fetch client url ~headers:(("Range", range) :: headers)
          ~start:offset ~len ()
        |> Producer.Error.lift_http_range
        |> Producer.Error.unwrap
      in
      body

(* Slice element bytes from an already-fetched buffer if it covers the whole
   element; otherwise issue an exact-bounded GET sized from the element
   header. [head_buf] is treated as the prefix [0, head_len). *)
let fetch_element ~client ~url ~headers ~head_buf ~abs_offset =
  let probe =
    read_bytes ~client ~url ~headers ~head_buf
      ~offset:abs_offset ~len:element_probe_size
  in
  let header = Ebml.parse_element_header probe ~pos:0 in
  let needed = header.header_size + header.data_size in
  match needed <= String.length probe with
  | true -> String.sub probe ~pos:0 ~len:needed
  | false ->
      read_bytes ~client ~url ~headers ~head_buf
        ~offset:abs_offset ~len:needed

let lookup_seek entries ~target_id =
  List.find_map entries ~f:(fun (e : Ebml.seek_entry) ->
    match e.target_id = target_id with
    | true -> Some e.position
    | false -> None)
  |> Option.value_or_thunk ~default:(fun () ->
    Producer.Error.raise_error
      (Producer.Error.Parse_error
         (Printf.sprintf "container.ebml: SeekHead missing entry for 0x%x" target_id)))

let parse client url ~headers : Byte_range_source.parsed =
  let head_range = Stdlib.Printf.sprintf "bytes=0-%d" (head_probe_size - 1) in
  let head_buf, total =
    Http_range.fetch client url ~headers:(("Range", head_range) :: headers)
      ~start:0 ~len:head_probe_size ()
    |> Producer.Error.lift_http_range
    |> Producer.Error.unwrap
  in
  let segment_data_start = Ebml.find_segment_data_start head_buf in
  let seek_head =
    Ebml.find_element head_buf ~id:Ebml.seek_head_id
      ~pos:segment_data_start ~limit:(String.length head_buf - segment_data_start)
    |> Option.value_or_thunk ~default:(fun () ->
      Producer.Error.raise_error
        (Producer.Error.Parse_error
           "container.ebml: SeekHead not in first 16KiB"))
  in
  let entries =
    Ebml.parse_seek_head head_buf
      ~pos:(seek_head.offset + seek_head.header_size)
      ~limit:seek_head.data_size
  in
  let abs id = segment_data_start + lookup_seek entries ~target_id:id in
  let info_abs   = abs Ebml.info_id in
  let tracks_abs = abs Ebml.tracks_id in
  let cues_abs   = abs Ebml.cues_id in
  let ebml_header =
    Ebml.find_element head_buf ~id:0x1A45_DFA3 ~pos:0
      ~limit:(String.length head_buf)
    |> Option.value_exn ~message:"container.ebml: missing EBML header"
  in
  let ebml_bytes =
    String.sub head_buf ~pos:ebml_header.offset
      ~len:(ebml_header.header_size + ebml_header.data_size)
  in
  let fetch off =
    fetch_element ~client ~url ~headers ~head_buf ~abs_offset:off
  in
  let info_bytes   = fetch info_abs in
  let tracks_bytes = fetch tracks_abs in
  let cues_bytes   = fetch cues_abs in
  let init_bytes =
    Ebml.webm_init_from_pieces ~ebml_bytes ~info_bytes ~tracks_bytes
  in
  let cue_points = Ebml.parse_cues_block cues_bytes in
  let timecode_scale, duration_ns = webm_info init_bytes in
  let to_usec_from_ticks ticks = ticks * timecode_scale / 1_000 in
  let total_duration_usec = Option.map duration_ns ~f:(fun ns -> ns / 1_000) in
  let cues_arr =
    cue_points
    |> List.map ~f:(fun (c : Ebml.cue_point) ->
        c.cue_time, segment_data_start + c.cluster_offset)
    |> Array.of_list
  in
  let n = Array.length cues_arr in
  let pairs =
    Array.mapi cues_arr ~f:(fun i (cue_time, off) ->
      let cue_start_usec = to_usec_from_ticks cue_time in
      let next_off, length_usec =
        match i + 1 < n with
        | true ->
            let next_time, next_off = cues_arr.(i + 1) in
            next_off, to_usec_from_ticks (next_time - cue_time)
        | false ->
            total,
            (match total_duration_usec with
             | Some td when td > cue_start_usec -> td - cue_start_usec
             | _ -> 0)
      in
      let info : Producer.Segment_info.t = {
        start_usec  = cue_start_usec;
        length_usec;
        byte_length = next_off - off;
      } in
      info, off)
  in
  let segments = Array.map pairs ~f:fst in
  let offsets  = Array.map pairs ~f:snd in
  Log.info (fun m ->
    m "parse ok: %d segments, %d bytes total, %d byte init"
      (Array.length segments) total (String.length init_bytes));
  { Byte_range_source.total_length = total; init_bytes; segments; offsets }

include Byte_range_source.Make (struct
  let container = Producer.Container.Webm
  let parse = parse
end)

