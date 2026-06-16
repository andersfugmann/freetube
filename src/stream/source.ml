open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HLS pipeline source (video + audio producers)" Stdlib.__MODULE__)

type rendition = [ `Video | `Audio ]

let rendition_name = function `Video -> "video" | `Audio -> "audio"

type t = {
  client : Http_client.t;
  video  : Producer.video Producer.t;
  audio  : Producer.audio Producer.t;
  video_stream : Youtube.Video_info.Stream.t;
  audio_stream : Youtube.Video_info.Stream.t;
  title : string;
  duration_seconds : float;
  is_live : bool;
  start_walltime_ms : int;
  storyboard : Storyboard.t Eio.Lazy.t option;
}

let ( |+> ) (type k) (module M : Producer.S with type kind = k) (module Y : Producer.Make) =
  let module W = Y.Make(M) in
  (module W : Producer.S with type kind = k)

let ( |?> ) (type k) (module M : Producer.S with type kind = k) (cond, (module Y : Producer.Make)) =
  match cond with
  | false -> (module M : Producer.S with type kind = k)
  | true ->
    (module M) |+> (module Y)

let chain (type k) ~transcode ~is_live (module M : Producer.S with type kind = k) =
  (module M : Producer.S with type kind = k)
  |+> (module Container_to_fmp4)
  |?> (transcode, (module Cache))
  |?> (transcode, (module Dedup))
  |?> (transcode, (module Prefetch))
  |?> (transcode, (module Transcode))
  |+> (module Brand_override)
  |+> (module Cache)
  |+> (module Dedup)
  |?> (is_live && false, (module Live_backoff))
  |+> (module Prefetch)


let has_noclen url =
  match Uri.get_query_param (Uri.of_string url) "noclen" with
  | Some "1" -> true
  | _ -> false

let container_of_source = function
  | Source_container.Mp4_dash | Source_container.M4a_dash -> Producer.Container.Mp4
  | Source_container.Webm_dash -> Producer.Container.Webm

let make_video ~clock ~client ~url ~headers ~is_live ~noclen ~codec ~dynamic_range ~rfc6381 source
  : (module Producer.S with type kind = Producer.video) =
  let container = container_of_source source in
  match noclen with
  | true ->
      let (module Base) =
        Segment_fetcher.create_video ~clock ~client ~url ~headers ~is_live
          ~container ~codec ~dynamic_range ~rfc6381 ()
      in
      (module Segment_split.Make(Base))
  | false ->
      match source with
      | Source_container.Mp4_dash ->
        Vod_mp4.create_video ~clock ~headers ~client ~url ~codec ~dynamic_range ~rfc6381 ()
      | Webm_dash ->
        Vod_webm.create_video ~clock ~headers ~client ~url ~codec ~dynamic_range ~rfc6381 ()
      | M4a_dash -> failwith "audio-only container m4a_dash not valid for video rendition"

let make_audio ~clock ~client ~url ~headers ~is_live ~noclen ~codec ~rfc6381 source
  : (module Producer.S with type kind = Producer.audio) =
  let container = container_of_source source in
  match noclen with
  | true ->
      let (module Base) =
        Segment_fetcher.create_audio ~clock ~client ~url ~headers ~is_live
          ~container ~codec ~rfc6381 ()
      in
      (module Segment_split.Make(Base))
  | false ->
      match source with
      | Source_container.M4a_dash ->
        Vod_mp4.create_audio ~clock ~headers ~client ~url ~codec ~rfc6381 ()
      | Webm_dash ->
        Vod_webm.create_audio ~clock ~headers ~client ~url ~codec ~rfc6381 ()
      | Mp4_dash -> failwith "video-only container mp4_dash not valid for audio rendition"

let source_of stream =
  Source_container.of_stream stream
  |> Option.value_or_thunk ~default:(fun () ->
       Printf.failwithf "unsupported container: %s"
         (Youtube.Video_info.Container.to_string stream.Youtube.Video_info.Stream.ext) ())

let all_video_codecs = Codec.Video.[ Av1; Hevc; Vp9; Avc ]
let all_audio_codecs = Codec.Audio.[ Opus; Aac; Vorbis; Flac ]

let init ~env ~sw ~video_codecs ~audio_codecs ~max_width ~max_height ~transcode youtube =
  let client =
    Http_client.init
      ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
      ~sw ~env ()
  in
  let clock = Eio.Stdenv.clock env in
  let is_live = youtube.Youtube.video_info.is_live in
  let select_video_codecs = match transcode with
    | true -> all_video_codecs
    | false -> video_codecs
  in
  let select_audio_codecs = match transcode with
    | true -> all_audio_codecs
    | false -> audio_codecs
  in
  let selection =
    Selector.select ~video_codecs:select_video_codecs ~audio_codecs:select_audio_codecs
      ~max_width ~max_height
      youtube.Youtube.video_info.streams
    |> Option.value_exn ~message:"no compatible stream"
  in
  match selection with
  | Selector.Muxed _ ->
      failwith "muxed/progressive streams not yet supported"
  | Separate { video; audio } ->
      let source_video_codec = fst (Option.value_exn video.vcodec) in
      let source_video_rfc6381 = snd (Option.value_exn video.vcodec) in
      let source_audio_codec = fst (Option.value_exn audio.acodec) in
      let source_audio_rfc6381 = snd (Option.value_exn audio.acodec) in
      let source_dynamic_range =
        Option.value video.dynamic_range ~default:Codec.Dynamic_range.Sdr
      in
      let width = Option.value video.width ~default:1920 in
      let height = Option.value video.height ~default:1080 in
      let fps = Option.value video.fps ~default:30.0 in
      (* Construct target shapes from sink capabilities *)
      let video_target : Producer.video Producer.Shape.t =
        match transcode with
        | false ->
          Producer.Shape.Video {
            container = Producer.Container.Mp4;
            codec = source_video_codec;
            dynamic_range = source_dynamic_range;
            rfc6381 = source_video_rfc6381;
          }
        | true ->
          let sink_video_codec =
            match List.find video_codecs ~f:(Codec.Video.equal source_video_codec) with
            | Some c -> c
            | None ->
              (* Prefer first in sink list (typically ordered by preference) *)
              List.hd_exn video_codecs
          in
          let sink_dynamic_range =
            match sink_video_codec with
            | Codec.Video.Hevc | Av1 | Vp9 -> source_dynamic_range
            | Avc | Unknown -> Codec.Dynamic_range.Sdr
          in
          Producer.Shape.Video {
            container = Producer.Container.Mp4;
            codec = sink_video_codec;
            dynamic_range = sink_dynamic_range;
            rfc6381 = Codec.Rfc6381.video ~codec:sink_video_codec ~width ~height ~fps;
          }
      in
      let audio_target : Producer.audio Producer.Shape.t =
        match transcode with
        | false ->
          Producer.Shape.Audio {
            container = Producer.Container.Mp4;
            codec = source_audio_codec;
            rfc6381 = source_audio_rfc6381;
          }
        | true ->
          let target_audio_codec = List.hd_exn audio_codecs in
          Producer.Shape.Audio {
            container = Producer.Container.Mp4;
            codec = target_audio_codec;
            rfc6381 = Codec.Rfc6381.audio target_audio_codec;
          }
      in
      let video_source = source_of video in
      let audio_source = source_of audio in
      let video_p =
        make_video ~clock ~client ~url:video.url ~is_live
          ~noclen:(has_noclen video.url) ~headers:video.http_headers
          ~codec:source_video_codec ~dynamic_range:source_dynamic_range
          ~rfc6381:source_video_rfc6381 video_source
        |> chain ~transcode ~is_live
        |> Producer.init ~env ~sw ~target:video_target
      in
      let audio_p =
        make_audio ~clock ~client ~url:audio.url ~is_live
          ~noclen:(has_noclen audio.url) ~headers:audio.http_headers
          ~codec:source_audio_codec ~rfc6381:source_audio_rfc6381 audio_source
        |> chain ~transcode ~is_live
        |> Producer.init ~env ~sw ~target:audio_target
      in
      let meta = Producer.info video_p in
      Log.info (fun m ->
        let raw_of opt = match opt with Some (_, r) -> r | None -> "?" in
        m "stream source: video=%s audio=%s is_live=%b noclen=%b"
          (raw_of video.vcodec) (raw_of audio.acodec) is_live (has_noclen video.url));

      let storyboard =
        match is_live with
        | true -> None
        | false ->
          Selector.select_storyboard youtube.Youtube.video_info.streams
          |> Option.map ~f:(fun sb -> Storyboard.init ~env ~sw ~client ~storyboard:sb)
      in
      { client; video = video_p; audio = audio_p;
        video_stream = video; audio_stream = audio;
        title = youtube.Youtube.video_info.title;
        duration_seconds = youtube.Youtube.video_info.duration_secs;
        is_live = meta.is_live; start_walltime_ms = meta.start_walltime_ms;
        storyboard }

let segments_array t rendition =
  match rendition with
  | `Video -> (Producer.info t.video).segments
  | `Audio -> (Producer.info t.audio).segments

(* Seconds behind the live edge a player should start, expressed as a
   configurable number of video segments. *)
let live_delay_secs t =
  let video_segs = segments_array t `Video in
  match Array.length video_segs with
  | 0 -> 0.0
  | n ->
    let total_usec =
      Array.fold video_segs ~init:0
        ~f:(fun acc (s : Producer.Segment_info.t) -> acc + s.length_usec)
    in
    let avg_usec = total_usec / n in
    Float.of_int ((Config.get ()).streaming.live_edge_segments * avg_usec)
    /. 1_000_000.

let container t ~rendition =
  let shape = match rendition with
    | `Video -> Producer.Shape.container (Producer.shape t.video)
    | `Audio -> Producer.Shape.container (Producer.shape t.audio)
  in
  shape

let iframe_stream t =
  Option.map t.storyboard ~f:Eio.Lazy.force

let master t ~session_id:_ ~base_url:_ ~profile =
  let avg_bw =
    match t.is_live with
    | true ->
        Hls.video_bitrate_bps t.video_stream + Hls.audio_bitrate_bps t.audio_stream
    | false ->
        let video_segs = segments_array t `Video in
        let audio_segs = segments_array t `Audio in
        Hls.average_bandwidth_bps video_segs + Hls.average_bandwidth_bps audio_segs
  in
  let video_rfc6381 = Producer.Shape.rfc6381 (Producer.shape t.video) in
  let audio_rfc6381 = Producer.Shape.rfc6381 (Producer.shape t.audio) in
  Hls.master ~profile ?iframe_stream:(iframe_stream t) ~title:t.title
    ~video:t.video_stream ~audio:t.audio_stream
    ~video_rfc6381 ~audio_rfc6381
    ~average_bandwidth_bps:avg_bw ()

let title t = t.title

let duration_seconds t = t.duration_seconds

(* For live streams there is no real duration; the seekable range is the DVR
   window the segment fetcher exposes. Surface it so DLNA can advertise a
   matching seekbar length. *)
let live_window_seconds () = Float.of_int (Segment_fetcher.window_seconds ())

let is_live t = t.is_live

let resolution t =
  match t.video_stream.width, t.video_stream.height with
  | Some w, Some h -> Some (w, h)
  | _ -> None

let media t ~base_url ~rendition ~profile =
  let segs = segments_array t rendition in
  let container = container t ~rendition in
  let media_sequence, program_date_time =
    match t.is_live, Array.length segs > 0 with
    | true, true ->
        let s0 = segs.(0) in
        s0.start_usec / s0.length_usec,
        Some t.start_walltime_ms
    | _ -> 0, None
  in
  Hls.media ~profile ~media_sequence ?program_date_time ~base_url
    ~rendition:(rendition_name rendition)
    ~ext:(Producer.Container.to_ext container)
    ~is_live:t.is_live ~live_delay_secs:(live_delay_secs t) segs

let dash_mpd t =
  let video_segments = segments_array t `Video in
  let audio_segments = segments_array t `Audio in
  let container = Producer.Shape.container (Producer.shape t.video) in
  let video_rfc6381 = Producer.Shape.rfc6381 (Producer.shape t.video) in
  let audio_rfc6381 = Producer.Shape.rfc6381 (Producer.shape t.audio) in
  Dash.mpd ~title:t.title ~is_live:t.is_live
    ~start_walltime_ms:t.start_walltime_ms ~container
    ~live_delay_secs:(live_delay_secs t)
    ~video:t.video_stream ~audio:t.audio_stream
    ~video_rfc6381 ~audio_rfc6381
    ~video_segments ~audio_segments ?iframe_stream:(iframe_stream t) ()

let init_segment t ~rendition =
  match rendition with
  | `Video -> Producer.init_segment t.video
  | `Audio -> Producer.init_segment t.audio

let segment t ~rendition ~id =
  match rendition with
  | `Video -> Producer.fetch_segment t.video ~id
  | `Audio -> Producer.fetch_segment t.audio ~id

let close t =
  (try Producer.close t.video with _ -> ());
  (try Producer.close t.audio with _ -> ())
