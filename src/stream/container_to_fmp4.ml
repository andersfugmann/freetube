
open! Base
open Util

(** Functor that normalises non-fMP4 containers (WebM, MPEG-TS) into
    fragmented MP4 segments. No transcoding — frames are copied verbatim.

    Reports [Producer.Container.Mp4] so downstream stages (Transcode,
    Brand_override, HLS muxer) can assume fMP4 input. *)

module Log = (val Log_src.src_log ~doc:"container to fMP4 remuxing producer" Stdlib.__MODULE__)

(* Convert WebM ticks (relative to TimecodeScale) into media timescale units. *)
let ticks_to_media ~timecode_scale_ns ~media_timescale ticks =
  let num = ticks * timecode_scale_ns in
  let den = 1_000_000_000 / media_timescale in
  num / den

let build_samples ~cluster_ticks_total blocks =
  let arr = Array.of_list blocks in
  let n = Array.length arr in
  Array.mapi arr ~f:(fun i (b : Ebml.simple_block) ->
    let next_delta =
      match i + 1 < n with
      | true  -> (Array.get arr (i + 1)).timecode_delta
      | false -> cluster_ticks_total
    in
    let duration_ticks = Int.max 0 (next_delta - b.timecode_delta) in
    duration_ticks, b)

(* Iterate every Cluster element in [buf]. YouTube WebM segments returned by
   the byte-range source span a Cue-to-Cue range that frequently contains
   multiple clusters; processing only the first dropped most frames. *)
let collect_clusters buf =
  let limit = String.length buf in
  let rec loop pos acc =
    match pos >= limit with
    | true -> List.rev acc
    | false ->
        let h = Ebml.parse_element_header buf ~pos in
        let next = pos + h.header_size + h.data_size in
        let acc =
          match h.id = Ebml.cluster_id with
          | true -> Ebml.parse_cluster_header buf ~pos :: acc
          | false -> acc
        in
        match next <= pos || next > limit with
        | true -> List.rev acc
        | false -> loop next acc
  in
  loop 0 []

(* ---------- init building ---------- *)

let pick_video_track tracks =
  List.find tracks ~f:(fun (t : Ebml.track_entry) ->
    match t.kind with Track_video -> true | _ -> false)

let pick_audio_track tracks =
  List.find tracks ~f:(fun (t : Ebml.track_entry) ->
    match t.kind with Track_audio -> true | _ -> false)

let av1_init (t : Ebml.track_entry) =
  let v = Option.value_exn ~message:"container_to_fmp4: AV1 track missing video element" t.video in
  let codec_private =
    Option.value_exn ~message:"container_to_fmp4: V_AV1 missing CodecPrivate" t.codec_private
  in
  let ext = [ Bmff_builder.av1c ~config_obus:codec_private ] in
  Bmff_builder.build_video_init ~four_cc:"av01" ~ext_boxes:ext
    ~timescale:1000 ~width:v.width ~height:v.height ~track_id:1

let vp9_init (t : Ebml.track_entry) =
  let v = Option.value_exn ~message:"container_to_fmp4: VP9 track missing video element" t.video in
  let colour = Option.bind v.colour ~f:(fun c -> Some c) in
  let primaries =
    Option.bind colour ~f:(fun c -> c.primaries) |> Option.value ~default:1
  in
  let transfer =
    Option.bind colour ~f:(fun c -> c.transfer_characteristics) |> Option.value ~default:1
  in
  let matrix =
    Option.bind colour ~f:(fun c -> c.matrix_coefficients) |> Option.value ~default:1
  in
  let full_range =
    Option.bind colour ~f:(fun c -> c.range) |> Option.value ~default:0 = 2
  in
  let bit_depth, chroma, profile, level =
    match t.codec_private with
    | Some cp when String.length cp >= 4 ->
        Char.to_int cp.[3], (Char.to_int cp.[2]) lsr 4, Char.to_int cp.[0], Char.to_int cp.[1]
    | _ -> 8, 1, 0, 30
  in
  let vpcc =
    Bmff_builder.vpcc ~profile ~level ~bit_depth
      ~chroma_subsampling:chroma ~video_full_range:full_range
      ~colour_primaries:primaries ~transfer_characteristics:transfer
      ~matrix_coefficients:matrix
  in
  Bmff_builder.build_video_init ~four_cc:"vp09" ~ext_boxes:[ vpcc ]
    ~timescale:1000 ~width:v.width ~height:v.height ~track_id:1

let opus_init (t : Ebml.track_entry) =
  let a = Option.value_exn ~message:"container_to_fmp4: Opus track missing audio element" t.audio in
  let opus_head =
    Option.value_exn ~message:"container_to_fmp4: A_OPUS missing CodecPrivate" t.codec_private
  in
  let dops = Bmff_builder.dops_from_opus_head opus_head in
  let preskip =
    match String.length opus_head >= 12 with
    | true ->
        let lo = Char.to_int opus_head.[10] in
        let hi = Char.to_int opus_head.[11] in
        lo lor (hi lsl 8)
    | false -> 0
  in
  let timescale = 48000 in
  let edts =
    match preskip > 0 with
    | true ->
        let media_duration =
          match t.default_duration_ns with
          | Some _ -> 0
          | None -> 0
        in
        Some (Bmff_builder.edts_preskip ~timescale ~skip_samples:preskip
                ~media_duration)
    | false -> None
  in
  let _ = a.sampling_frequency in
  Bmff_builder.build_audio_init ~four_cc:"Opus" ~ext_boxes:[ dops ]
    ~timescale ~channels:a.channels ~sample_rate:timescale
    ~track_id:1 ?edts ()

let parse_init_webm ~kind (webm_init : string) =
  let length = String.length webm_init in
  let segment =
    Ebml.find_element webm_init ~id:Ebml.segment_id ~pos:0 ~limit:length
    |> Option.value_exn ~message:"container_to_fmp4: missing Segment"
  in
  let seg_pos = segment.offset + segment.header_size in
  let info =
    Ebml.find_element webm_init ~id:Ebml.info_id ~pos:seg_pos ~limit:segment.data_size
    |> Option.value_exn ~message:"container_to_fmp4: missing Info"
  in
  let timecode_scale_ns, _ =
    Ebml.parse_segment_info webm_init
      ~pos:(info.offset + info.header_size) ~limit:info.data_size
  in
  let tracks_h =
    Ebml.find_element webm_init ~id:Ebml.tracks_id ~pos:seg_pos ~limit:segment.data_size
    |> Option.value_exn ~message:"container_to_fmp4: missing Tracks"
  in
  let tracks =
    Ebml.parse_tracks webm_init
      ~pos:(tracks_h.offset + tracks_h.header_size)
      ~limit:tracks_h.data_size
  in
  let track =
    match kind with
    | `Video -> pick_video_track tracks
    | `Audio -> pick_audio_track tracks
  in
  let track =
    Option.value_exn track
      ~message:(Printf.sprintf "container_to_fmp4: no %s track in WebM init"
                  (match kind with `Video -> "video" | `Audio -> "audio"))
  in
  let init_bytes, media_timescale =
    match track.codec_id with
    | "V_AV1"  -> av1_init  track, 1000
    | "V_VP9"  -> vp9_init  track, 1000
    | "A_OPUS" -> opus_init track, 48000
    | other    -> Printf.failwithf "container_to_fmp4: unsupported codec %s" other ()
  in
  init_bytes, track.track_number, timecode_scale_ns, media_timescale

let kind_of_witness : type k. k Producer.Kind.witness -> [ `Video | `Audio ] = function
  | Producer.Kind.Video -> `Video
  | Producer.Kind.Audio -> `Audio
  | Producer.Kind.Muxed -> `Video

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state =
    | Passthrough of M.state
    | Remux of {
        inner             : M.state;
        init_bytes        : string;
        track_number      : int;
        timecode_scale_ns : int;
        media_timescale   : int;
        mutable next_sequence : int;
        mutable next_segment_id : int;
      }
  type kind = M.kind
  let witness = M.witness

  let init ~env ~sw ~target =
    let inner, inner_shape = M.init ~env ~sw ~target in
    match M.witness with
    | Producer.Kind.Muxed -> failwith "container_to_fmp4: muxed not supported"
    | _ ->
      match Producer.Shape.container inner_shape with
      | Producer.Container.Mp4 ->
        Passthrough inner, inner_shape
      | Producer.Container.Webm ->
        let kind = kind_of_witness M.witness in
        let init_bytes, track_number, timecode_scale_ns, media_timescale =
          parse_init_webm ~kind (M.init_segment inner)
        in
        Log.info (fun m ->
          m "container_to_fmp4: track=%d ts_ns=%d media_ts=%d init=%d bytes"
            track_number timecode_scale_ns media_timescale (String.length init_bytes));
        let out_shape = Producer.Shape.with_container inner_shape Producer.Container.Mp4 in
        Remux { inner; init_bytes; track_number; timecode_scale_ns;
                media_timescale; next_sequence = 1; next_segment_id = 0 },
        out_shape
      | Producer.Container.Mpeg_ts ->
        failwith "container_to_fmp4: mpeg_ts remuxing not supported"

  let info = function
    | Passthrough inner -> M.info inner
    | Remux s -> M.info s.inner

  let init_segment = function
    | Passthrough inner -> M.init_segment inner
    | Remux s -> s.init_bytes

  let max_segment_id = function
    | Passthrough inner -> M.max_segment_id inner
    | Remux s -> M.max_segment_id s.inner

  let close = function
    | Passthrough inner -> M.close inner
    | Remux s -> M.close s.inner

  let fetch_segment s ~id =
    match s with
    | Passthrough inner -> M.fetch_segment inner ~id
    | Remux s ->
      let inner_seg = M.fetch_segment s.inner ~id in
      let buf = inner_seg.data in
      let clusters = collect_clusters buf in
      let segment_ticks_total =
        inner_seg.length_usec * 1000 / s.timecode_scale_ns
      in
      let segment_end_tc =
        match clusters with
        | first :: _ -> first.timecode + segment_ticks_total
        | [] -> 0
      in
      let clusters_arr = Array.of_list clusters in
      let n_clusters = Array.length clusters_arr in
      let cluster_end_tc i =
        match i + 1 < n_clusters with
        | true -> clusters_arr.(i + 1).timecode
        | false -> segment_end_tc
      in
      let base_sequence =
        match id = s.next_segment_id with
        | true -> s.next_sequence
        | false -> (id + 1) * 2
      in
      let ticks_to_media = ticks_to_media ~timecode_scale_ns:s.timecode_scale_ns
          ~media_timescale:s.media_timescale in
      let buffer = Buffer.create (String.length buf) in
      let fragments_rev =
        Array.foldi clusters_arr ~init:[] ~f:(fun i acc (cluster : Ebml.cluster) ->
          let blocks =
            Ebml.parse_cluster_blocks buf cluster
            |> List.filter ~f:(fun (b : Ebml.simple_block) ->
                 b.track_number = s.track_number)
          in
          let cluster_ticks_total =
            Int.max 0 (cluster_end_tc i - cluster.timecode)
          in
          let samples_with_blocks = build_samples ~cluster_ticks_total blocks in
          Buffer.clear buffer;
          Array.iter samples_with_blocks ~f:(fun (_, sb) ->
            Buffer.add_substring buffer buf ~pos:sb.frame_offset ~len:sb.frame_len);
          let payload = Buffer.contents buffer in
          let samples =
            Array.to_list samples_with_blocks
            |> List.map ~f:(fun (dur_ticks, (sb : Ebml.simple_block)) ->
                 { Bmff_builder.
                   duration = ticks_to_media dur_ticks;
                   size = sb.frame_len;
                   flags = 0;
                   is_keyframe = sb.keyframe })
          in
          let base_decode_time = ticks_to_media cluster.timecode in
          let fragment =
            Bmff_builder.build_fragment
              ~sequence:(base_sequence + i)
              ~track_id:1
              ~base_decode_time
              ~samples
              ~payload
          in
          fragment :: acc)
      in
      s.next_sequence <- base_sequence + n_clusters;
      s.next_segment_id <- id + 1;
      let data = String.concat ~sep:"" (List.rev fragments_rev) in
      { Producer.Segment.start_usec = inner_seg.start_usec;
        length_usec = inner_seg.length_usec;
        data }
end
