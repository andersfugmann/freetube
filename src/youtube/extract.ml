open! Base
open Util

module Log = (val Log_src.src_log ~doc:"yt-dlp video extraction" Stdlib.__MODULE__)

let max_output_size = 16 * 1024 * 1024

let read_all flow =
  Eio.Buf_read.parse_exn ~max_size:max_output_size Eio.Buf_read.take_all flow

let argv ~cookie_path video_id =
  let ip_flag =
    match (Config.get ()).network.yt_dlp_force_ipv6 with
    | true -> ["--force-ipv6"]
    | false -> []
  in
  ["/usr/bin/yt-dlp"]
  @ ip_flag
  @ [
    "--js-runtimes"; "deno";
    "--remote-components"; "ejs:github";
    "--extractor-args";
    "youtube:formats=incomplete";
    "--cookies"; cookie_path;
    "-j";
    "--"; video_id
  ]

let status_message status stderr =
  match status with
  | `Exited code -> Printf.sprintf "yt-dlp exited with code %d : %s" code stderr
  | `Signaled signal -> Printf.sprintf "yt-dlp killed by signal %d : %s" signal stderr

let parse_video_info stdout =
  Yojson.Safe.from_string stdout
  |> Video_info.of_yojson
  |> Result.ok_or_failwith

let file_size_or_minus_one path =
  Eio_unix.run_in_systhread (fun () ->
    try (Unix.stat path).st_size
    with
    | Unix.Unix_error _ -> -1
    | Sys_error _ -> -1)

let extract_json ~timeout ~env ~cookie_path video_id =
  let clock = Eio.Stdenv.clock env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  Eio.Time.with_timeout_exn clock timeout (fun () ->
      Eio.Switch.run @@ fun sw ->
      let args = argv ~cookie_path video_id in
      let cookie_size = file_size_or_minus_one cookie_path in
      Log.info (fun m ->
        m "spawning yt-dlp: cookie_path=%s cookie_bytes=%d argv=%s"
          cookie_path cookie_size
          (String.concat ~sep:" " (List.map args ~f:(Printf.sprintf "%S"))));
      let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
      let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
      let process =
        Eio.Process.spawn ~sw proc_mgr ~stdin:(Eio.Flow.string_source "")
          ~stdout:stdout_w ~stderr:stderr_w args
      in
      Eio.Flow.close stdout_w;
      Eio.Flow.close stderr_w;
      let stdout, stderr =
        Eio.Fiber.pair (fun () -> read_all stdout_r) (fun () -> read_all stderr_r)
      in
      match Eio.Process.await process with
      | `Exited 0 -> Yojson.Safe.from_string stdout
      | (`Exited _ | `Signaled _) as status ->
        failwith (status_message status stderr)
    )

let extract ~timeout ~env ~cookie_path video_id =
  extract_json ~timeout ~env ~cookie_path video_id
  |> Video_info.of_yojson
  |> Result.ok_or_failwith
