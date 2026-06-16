open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Segment init/data splitter" Stdlib.__MODULE__)

let default_target_duration_us = 5_000_000

let parse_target_duration_us data =
  match String.substr_index data ~pattern:"Target-Duration-Us: " with
  | None -> None
  | Some i ->
      let start = i + String.length "Target-Duration-Us: " in
      let len = String.length data in
      let rec scan_digits pos =
        match pos < len && Char.is_digit (String.get data pos) with
        | true -> scan_digits (pos + 1)
        | false -> pos
      in
      let end_pos = scan_digits start in
      match end_pos > start with
      | true -> Some (Int.of_string (String.sub data ~pos:start ~len:(end_pos - start)))
      | false -> None

(* --- fMP4 splitting --- *)

let split_mp4 body =
  let len = String.length body in
  let rec find_moof pos =
    match pos + 8 <= len with
    | false -> None
    | true ->
        let box_size = Bmff.get_u32_be body pos in
        let box_type = String.sub body ~pos:(pos + 4) ~len:4 in
        match String.equal box_type "moof" with
        | true -> Some pos
        | false ->
            match box_size with
            | 0 -> None
            | _ -> find_moof (pos + box_size)
  in
  let rec find_moov_end pos =
    match pos + 8 <= len with
    | false -> pos
    | true ->
        let box_size = Bmff.get_u32_be body pos in
        let box_type = String.sub body ~pos:(pos + 4) ~len:4 in
        match String.equal box_type "ftyp" || String.equal box_type "moov" with
        | true -> find_moov_end (pos + box_size)
        | false -> pos
  in
  match find_moof 0 with
  | None -> body, ""
  | Some moof_offset ->
      let init_end = find_moov_end 0 in
      String.prefix body init_end,
      String.drop_prefix body moof_offset

let mp4_segment_duration_usec data =
  parse_target_duration_us data
  |> Option.value ~default:default_target_duration_us

(* --- WebM splitting --- *)

let split_webm body =
  let init_bytes = Ebml.build_webm_init body in
  let length = String.length body in
  let segment =
    Ebml.find_element body ~id:Ebml.segment_id ~pos:0 ~limit:length
    |> Option.value_exn ~message:"segment_split: missing Segment element"
  in
  let seg_data_start = segment.offset + segment.header_size in
  let cluster =
    Ebml.find_element body ~id:Ebml.cluster_id
      ~pos:seg_data_start ~limit:(length - seg_data_start)
    |> Option.value_exn ~message:"segment_split: missing Cluster element"
  in
  let data = String.drop_prefix body cluster.offset in
  init_bytes, data

let webm_segment_duration_usec data =
  let target_us =
    parse_target_duration_us data
    |> Option.value ~default:default_target_duration_us
  in
  let target_ns = target_us * 1000 in
  let length = String.length data in
  let segment =
    Ebml.find_element data ~id:Ebml.segment_id ~pos:0 ~limit:length
    |> Option.value_exn ~message:"segment_split: missing Segment element"
  in
  let seg_data_start = segment.offset + segment.header_size in
  let tracks =
    Ebml.find_element data ~id:Ebml.tracks_id ~pos:seg_data_start
      ~limit:segment.data_size
    |> Option.value_exn ~message:"segment_split: missing Tracks element"
  in
  let entries =
    Ebml.parse_tracks data
      ~pos:(tracks.offset + tracks.header_size)
      ~limit:tracks.data_size
  in
  let default_duration_ns =
    List.find_map entries ~f:(fun (e : Ebml.track_entry) -> e.default_duration_ns)
  in
  match default_duration_ns with
  | Some ns ->
      let frames = Float.iround_nearest_exn (Float.of_int target_ns /. Float.of_int ns) in
      frames * ns / 1000
  | None -> target_us

(* --- Dispatch by container --- *)

let split container body =
  match container with
  | Producer.Container.Mp4 -> split_mp4 body
  | Producer.Container.Webm -> split_webm body
  | Producer.Container.Mpeg_ts -> failwith "segment_split: mpeg_ts not supported"

let compute_duration container body =
  match container with
  | Producer.Container.Mp4 -> mp4_segment_duration_usec body
  | Producer.Container.Webm -> webm_segment_duration_usec body
  | Producer.Container.Mpeg_ts -> default_target_duration_us

(* --- Pipeline functor --- *)

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner              : M.state;
    container          : Producer.Container.kind;
    mutable init_bytes : string option;
    mutable segment_duration_usec : int;
  }
  type kind = M.kind
  let witness = M.witness

  let init ~env ~sw ~target =
    let inner, shape = M.init ~env ~sw ~target in
    let container = Producer.Shape.container shape in
    { inner; container; init_bytes = None;
      segment_duration_usec = default_target_duration_us }, shape

  let info s = M.info s.inner

  let init_segment s =
    match s.init_bytes with
    | Some cached -> cached
    | None ->
        let raw = M.init_segment s.inner in
        let init_bytes, _data = split s.container raw in
        s.segment_duration_usec <- compute_duration s.container raw;
        Log.info (fun m ->
          m "init parsed: container=%s init_bytes=%d segment_duration_usec=%d"
            (Producer.Container.string_of_kind s.container)
            (String.length init_bytes) s.segment_duration_usec);
        s.init_bytes <- Some init_bytes;
        init_bytes

  let max_segment_id s = M.max_segment_id s.inner
  let close s = M.close s.inner

  let fetch_segment s ~id =
    let seg = M.fetch_segment s.inner ~id in
    let _init, data = split s.container seg.data in
    { seg with data;
               length_usec = s.segment_duration_usec }
end
