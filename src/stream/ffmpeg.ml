open! Base
open Util

module Log = (val Log_src.src_log ~doc:"FFmpeg transcoding runner" Stdlib.__MODULE__)

let default_vaapi_device = "/dev/dri/renderD128"
let max_segment_output = 64 * 1024 * 1024

let read_all flow =
  Eio.Buf_read.parse_exn ~max_size:max_segment_output Eio.Buf_read.take_all flow

type dynamic_range_policy = Passthrough | Tonemap_to_sdr

type video_params = {
  video_codec : Codec.Video.t;
  dynamic_range : dynamic_range_policy;
}

type audio_params = {
  audio_codec : Codec.Audio.t;
}

let video_encoder_name = function
  | Codec.Video.Hevc -> "hevc_vaapi"
  | Avc -> "h264_vaapi"
  | Av1 -> "av1_vaapi"
  | Vp9 -> failwith "ffmpeg: vp9 vaapi encode not supported"
  | Unknown -> failwith "ffmpeg: unknown video codec"

let video_args ~input_format params =
  let encoder = video_encoder_name params.video_codec in
  let vaapi_device =
    Option.value (Config.get ()).gpu_device ~default:default_vaapi_device
  in
  let tonemap_filter = match params.dynamic_range with
    | Passthrough -> []
    | Tonemap_to_sdr ->
      ["-vf"; "scale_vaapi=format=nv12:out_color_transfer=bt709:out_color_matrix=bt709:out_color_primaries=bt709"]
  in
  [ "-hwaccel"; "vaapi";
    "-hwaccel_output_format"; "vaapi";
    "-hwaccel_device"; vaapi_device;
    "-f"; input_format;
    "-i"; "pipe:0";
    "-an" ]
  @ tonemap_filter
  @ [ "-c:v"; encoder;
      "-qp"; "26";
      "-movflags"; "+frag_keyframe+empty_moov+default_base_moof";
      "-f"; "mp4";
      "pipe:1" ]

let audio_args ~input_format params =
  let encoder = match params.audio_codec with
    | Codec.Audio.Aac -> "aac"
    | Opus -> "libopus"
    | Flac -> "flac"
    | Vorbis -> "libvorbis"
    | Unknown -> failwith "ffmpeg: unknown audio codec"
  in
  [ "-f"; input_format;
    "-i"; "pipe:0";
    "-vn";
    "-c:a"; encoder;
    "-b:a"; "256k";
    "-movflags"; "+frag_keyframe+empty_moov+default_base_moof";
    "-f"; "mp4";
    "pipe:1" ]

let run_ffmpeg ~env args input =
  let cmd = "ffmpeg" :: "-hide_banner" :: "-loglevel" :: "warning" :: args in
  Log.debug (fun m -> m "ffmpeg: %s" (String.concat ~sep:" " cmd));
  let proc_mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let stdin_r, stdin_w = Eio.Process.pipe ~sw proc_mgr in
  let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
  let process =
    Eio.Process.spawn ~sw proc_mgr
      ~stdin:stdin_r ~stdout:stdout_w ~stderr:stderr_w
      cmd
  in
  Eio.Flow.close stdin_r;
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  let write_result =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Flow.copy_string input stdin_w;
      Eio.Flow.close stdin_w)
  in
  let output, errors =
    Eio.Fiber.pair
      (fun () -> read_all stdout_r)
      (fun () -> Eio.Buf_read.parse_exn ~max_size:(64 * 1024) Eio.Buf_read.take_all stderr_r)
  in
  (match Eio.Promise.await write_result with
   | Ok () -> ()
   | Error _ -> ());
  match Eio.Process.await process with
  | `Exited 0 ->
    (match String.is_empty errors with
     | true -> ()
     | false -> Log.debug (fun m -> m "ffmpeg stderr: %s" errors));
    output
  | `Exited code ->
    failwith (Printf.sprintf "ffmpeg exited %d: %s" code errors)
  | `Signaled signal ->
    failwith (Printf.sprintf "ffmpeg killed by signal %d: %s" signal errors)

let transcode_video ~env ~input_format ~params input =
  run_ffmpeg ~env (video_args ~input_format params) input

let transcode_audio ~env ~input_format ~params input =
  run_ffmpeg ~env (audio_args ~input_format params) input
