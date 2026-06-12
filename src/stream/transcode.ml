open! Base
open Util

module Log = (val Log_src.src_log ~doc:"transcoding producer" Stdlib.__MODULE__)

let split_init_and_segment output =
  let limit = String.length output in
  let moof =
    Bmff.find_box output ~box_type:"moof" ~pos:0 ~limit
    |> Option.value_exn ~message:"transcode: no moof in ffmpeg output"
  in
  let init_data = String.sub output ~pos:0 ~len:moof.offset in
  let segment_data = String.sub output ~pos:moof.offset ~len:(limit - moof.offset) in
  init_data, segment_data

let input_format_of_container = function
  | Producer.Container.Mp4 -> "mp4"
  | Webm -> "matroska"
  | Mpeg_ts -> "mpegts"

let needs_transcode : type k. k Producer.Shape.t -> k Producer.Shape.t -> bool =
  fun source target ->
  match source, target with
  | Producer.Shape.Video src, Producer.Shape.Video dst ->
    not (Codec.Video.equal src.codec dst.codec)
    || not (Codec.Dynamic_range.equal src.dynamic_range dst.dynamic_range)
  | Producer.Shape.Audio src, Producer.Shape.Audio dst ->
    not (Codec.Audio.equal src.codec dst.codec)
  | Producer.Shape.Muxed _, _ ->
    failwith "transcode: muxed not supported"

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state =
    | Passthrough of M.state
    | Transcode of {
        inner : M.state;
        env : Eio_unix.Stdenv.base;
        input_format : string;
        video_params : Ffmpeg.video_params option;
        audio_params : Ffmpeg.audio_params option;
        semaphore : Eio.Semaphore.t;
        mutable init_seg : string option;
        mutable input_timescale : int;
        mutable output_timescale : int;
      }
  type kind = M.kind
  let witness = M.witness

  let init ~env ~sw ~target =
    let inner, inner_shape = M.init ~env ~sw ~target in
    match needs_transcode inner_shape target with
    | false -> Passthrough inner, inner_shape
    | true ->
      let input_format =
        input_format_of_container (Producer.Shape.container inner_shape)
      in
      let video_params, audio_params =
        match M.witness, target with
        | Producer.Kind.Video, Producer.Shape.Video dst ->
          let dynamic_range =
            match Codec.Dynamic_range.equal dst.dynamic_range Codec.Dynamic_range.Sdr with
            | true -> Ffmpeg.Tonemap_to_sdr
            | false -> Ffmpeg.Passthrough
          in
          Some { Ffmpeg.video_codec = dst.codec; dynamic_range }, None
        | Producer.Kind.Audio, Producer.Shape.Audio dst ->
          None, Some { Ffmpeg.audio_codec = dst.codec }
        | Producer.Kind.Muxed, _ ->
          failwith "transcode: muxed not supported"
      in
      Transcode { inner; env; input_format; video_params; audio_params;
                  semaphore = Eio.Semaphore.make (Config.get ()).max_ffmpeg_per_stream;
                  init_seg = None;
                  input_timescale = 0; output_timescale = 0 },
      Producer.Shape.with_container target Producer.Container.Mp4

  let meta = function
    | Passthrough inner -> M.meta inner
    | Transcode { inner; _ } -> M.meta inner

  let run_transcode ~env ~input_format ~video_params ~audio_params ~semaphore input =
    Eio.Semaphore.acquire semaphore;
    Exn.protect ~finally:(fun () -> Eio.Semaphore.release semaphore) ~f:(fun () ->
      match video_params with
      | Some params -> Ffmpeg.transcode_video ~env ~input_format ~params input
      | None ->
        let params = Option.value_exn audio_params in
        Ffmpeg.transcode_audio ~env ~input_format ~params input)

  let compute_offset ~input_timescale ~output_timescale input_segment_data =
    let input_bdt = Bmff.get_base_media_decode_time input_segment_data in
    Int64.(input_bdt * of_int output_timescale / of_int input_timescale)

  let init_segment = function
    | Passthrough inner -> M.init_segment inner
    | Transcode s ->
      match s.init_seg with
      | Some seg -> seg
      | None ->
        let upstream_init = M.init_segment s.inner in
        let upstream_seg = M.fetch_segment s.inner ~id:0 in
        let input = upstream_init ^ upstream_seg.data in
        s.input_timescale <- Bmff.mdhd_timescale upstream_init;
        let output =
          run_transcode ~env:s.env ~input_format:s.input_format
            ~video_params:s.video_params ~audio_params:s.audio_params
            ~semaphore:s.semaphore input
        in
        let init_data, _ = split_init_and_segment output in
        s.output_timescale <- Bmff.mdhd_timescale init_data;
        s.init_seg <- Some init_data;
        init_data

  let segments = function
    | Passthrough inner -> M.segments inner
    | Transcode { inner; _ } -> M.segments inner

  let max_segment_id = function
    | Passthrough inner -> M.max_segment_id inner
    | Transcode { inner; _ } -> M.max_segment_id inner

  let close = function
    | Passthrough inner -> M.close inner
    | Transcode { inner; _ } -> M.close inner

  let fetch_segment s ~id =
    match s with
    | Passthrough inner -> M.fetch_segment inner ~id
    | Transcode s ->
      let upstream_init = M.init_segment s.inner in
      let upstream_seg = M.fetch_segment s.inner ~id in
      let input = upstream_init ^ upstream_seg.data in
      let clock = Eio.Stdenv.clock s.env in
      let t0 = Eio.Time.now clock in
      let output =
        run_transcode ~env:s.env ~input_format:s.input_format
          ~video_params:s.video_params ~audio_params:s.audio_params
          ~semaphore:s.semaphore input
      in
      let elapsed = Eio.Time.now clock -. t0 in
      let seg_duration = Float.of_int upstream_seg.length_usec /. 1_000_000. in
      let speed = seg_duration /. elapsed in
      let kind = match s.video_params with Some _ -> "video" | None -> "audio" in
      Log.info (fun m ->
        m "transcode %s seg=%d time=%.0fms speed=%.1fx" kind id (elapsed *. 1000.) speed);
      let init_data, segment_data = split_init_and_segment output in
      (match s.init_seg with
       | Some _ -> ()
       | None ->
         s.input_timescale <- Bmff.mdhd_timescale upstream_init;
         s.output_timescale <- Bmff.mdhd_timescale init_data;
         s.init_seg <- Some init_data);
      let offset =
        compute_offset ~input_timescale:s.input_timescale
          ~output_timescale:s.output_timescale upstream_seg.data
      in
      let segment_data = Bmff.shift_base_media_decode_times segment_data ~offset in
      Log.info (fun m ->
        let bdt_secs = Int64.to_float offset /. Float.of_int s.output_timescale in
        m "transcode %s seg=%d baseMediaDecodeTime=%Ld (%.3fs) timescale=%d"
          kind id offset bdt_secs s.output_timescale);
      { Producer.Segment.
        start_usec = upstream_seg.start_usec;
        length_usec = upstream_seg.length_usec;
        data = segment_data }
end
