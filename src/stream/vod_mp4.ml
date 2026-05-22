
open! Base
open Util

(** YouTube VOD fetcher for fMP4 containers (AVC/HEVC video, AAC audio).
    Probes [moov]+[sidx] then exposes each fMP4 fragment as a Producer
    segment. *)

module Log = (val Log_src.src_log ~doc:"YouTube VOD MP4 fetch" Stdlib.__MODULE__)

let parse client url ~headers : Byte_range_source.parsed =
  let body_parse body total =
    match Bmff.find_box body ~box_type:"moov" ~pos:0
            ~limit:(String.length body) with
    | None -> raise Probe.Need_more
    | Some moov ->
        let init_bytes = String.sub body ~pos:0 ~len:(moov.offset + moov.size) in
        init_bytes, moov.offset + moov.size, total
  in
  let init_bytes, scan_start, total =
    Probe.probe_and_parse ~client ~url ~headers
      ~start:0 ~size:Probe.initial_probe_bytes
      ~max_size:Probe.max_probe_bytes body_parse
    |> Probe.or_parse_error "moov not found within probe limit"
    |> Producer.Error.unwrap
  in
  let fetch_sidx_chunk pos len =
    let range = Stdlib.Printf.sprintf "bytes=%d-%d" pos (pos + len - 1) in
    Http_range.fetch client url ~headers:(("Range", range) :: headers)
      ~start:pos ~len ()
    |> Producer.Error.lift_http_range
    |> Producer.Error.unwrap
    |> fst
  in
  let rec walk pos acc =
    match pos >= total with
    | true -> List.rev acc
    | false ->
        let header_buf = fetch_sidx_chunk pos (Int.min 64 (total - pos)) in
        let header = Bmff.parse_box_header header_buf ~pos:0 in
        match String.equal header.box_type "sidx" with
        | false -> List.rev acc
        | true ->
            let sidx_bytes = fetch_sidx_chunk pos header.size in
            let sidx = Bmff.parse_sidx sidx_bytes ~pos:0 in
            let base = pos + header.size in
            let ranges = Bmff.segment_ranges sidx ~base_offset:base in
            let next_pos =
              List.fold ranges ~init:base ~f:(fun off (r : Bmff.segment_range) ->
                Int.max off (r.offset + r.length))
            in
            walk next_pos (List.rev_append ranges acc)
  in
  let ranges = walk scan_start [] in
  let _, rev_segs, rev_offs =
    List.fold ranges ~init:(0, [], [])
      ~f:(fun (acc_usec, acc_segs, acc_offs)
              (r : Bmff.segment_range) ->
        let length_usec =
          Probe.usec_of_ticks
            ~ticks:r.duration_ticks ~timescale:r.timescale
        in
        let info : Producer.Segment_info.t = {
          start_usec  = acc_usec;
          length_usec;
          byte_length = r.length;
        } in
        acc_usec + length_usec, info :: acc_segs, r.offset :: acc_offs)
  in
  let segments = rev_segs |> List.rev |> Array.of_list in
  let offsets  = rev_offs |> List.rev |> Array.of_list in
  Log.info (fun m ->
    m "parse ok: %d segments, %d bytes total, %d byte init"
      (Array.length segments) total (String.length init_bytes));
  { Byte_range_source.total_length = total; init_bytes; segments; offsets }

include Byte_range_source.Make (struct
  let container = Producer.Container.Mp4
  let parse = parse
end)
