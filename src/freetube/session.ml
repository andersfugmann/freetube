open! Base
open Util
open Devices

module Sink = Sink

module Log = (val Log_src.src_log ~doc:"Client session = source pipeline + optional sink" Stdlib.__MODULE__)

type content =
  | Stream of Stream.Source.t
  | Direct of Uri.t

let max_reconstruct_attempts = 1

type t = {
  id: string;
  created_at: float;
  mutable last_accessed_at : float;
  content_factory: sw:Eio.Switch.t -> content;
  sink_factory: sw:Eio.Switch.t -> content:content -> Sink.t;
  mutable content: content option;
  mutable sink: Sink.t;
  mutable sw: Eio.Switch.t option;
  mutable retries_remaining: int;
  mutable closed: bool;
  ttl: float;
  clock: float Eio.Time.clock_ty Eio.Resource.t;
}

let id t = t.id
let created_at t = t.created_at
let last_accessed_at t = t.last_accessed_at
let content t = t.content
let sink t = t.sink

let stream t =
  match t.content with
  | Some (Stream s) -> Some s
  | _ -> None

let touch t = t.last_accessed_at <- Eio.Time.now t.clock

let stop t =
  Eio.Switch.fail (Option.value_exn t.sw) (Failure "session stopped")

let init ~id ~clock ~ttl ~content_factory ~sink_factory =
  let now = Eio.Time.now clock in
  { id;
    created_at = now;
    last_accessed_at = now;
    content_factory;
    sink_factory;
    content = None;
    sink = Sink.Url_consumer;
    sw = None;
    retries_remaining = max_reconstruct_attempts;
    closed = false;
    ttl;
    clock }

let close t =
  match t.closed with
  | true -> ()
  | false ->
    t.closed <- true;
    Log.info (fun m ->
      m "close session %s sink=%s" t.id
        (Sink.kind_to_string (Sink.kind t.sink)));
    Sink.close t.sink;
    (match t.content with
     | Some (Stream s) -> (try Stream.Source.close s with _ -> ())
     | _ -> ());
    stop t

(* ── Request handling ──────────────────────────────────────────── *)

let profile_of_vendor : Vendor.t -> Stream.Hls.profile = function
  | Apple   -> { independent_segments = true;  playlist_type = true;  session_data = true;  start_offset = true }
  | Samsung -> { independent_segments = false; playlist_type = false; session_data = false; start_offset = false }
  | Lg      -> { independent_segments = true;  playlist_type = true;  session_data = false; start_offset = true }
  | Generic -> { independent_segments = true;  playlist_type = true;  session_data = true;  start_offset = true }

let mime_of ~rendition ~(container : Stream.Producer.Container.kind) =
  match container, rendition with
  | Mpeg_ts, _    -> "video/mp2t"
  | Mp4,  `Video  -> "video/mp4"
  | Mp4,  `Audio  -> "audio/mp4"
  | Webm, `Video  -> "video/webm"
  | Webm, `Audio  -> "audio/webm"

type response = { content_type: string; body: string }

type request_error =
  | Not_found
  | No_stream
  | Unavailable of string

let error_f fmt =
  Printf.ksprintf (fun s -> Error (Unavailable s)) fmt

let parse_rendition = function
  | "video" -> Ok `Video
  | "audio" -> Ok `Audio
  | s -> error_f "Unknown Rendition: %s" s

let parse_seg s =
  String.lsplit2 s ~on:'.'
  |> Option.map ~f:fst
  |> Option.bind ~f:Int.of_string_opt
  |> Result.of_option ~error:(Unavailable (Printf.sprintf "Could not parse segment id: %s" s))

let ensure_content t =
  match t.content with
  | Some c -> c
  | None ->
    let sw = Option.value_exn t.sw ~message:"session not running" in
    let c = t.content_factory ~sw in
    t.content <- Some c;
    c

let serve t ~path =
  let ( let* ) o f = Result.bind ~f o in
  let content = ensure_content t in
  match content with
  | Direct _ -> Error No_stream
  | Stream source ->
    let profile = profile_of_vendor (Sink.vendor t.sink) in
    let base_url = "/sessions/" ^ t.id in
    match path with
    | ["master.m3u8"] ->
      let body = Stream.Source.master source
          ~session_id:t.id ~base_url ~profile in
      Ok { content_type = "application/vnd.apple.mpegurl"; body }
    | ["dash.mpd"] ->
      let body = Stream.Source.dash_mpd source in
      Ok { content_type = Stream.Dash.content_type; body }
    | ["storyboard"; "media.m3u8"] ->
      (match Stream.Source.storyboard source with
       | None -> Error Not_found
       | Some sb ->
         let body = Stream.Hls.storyboard_media sb in
         Ok { content_type = "application/vnd.apple.mpegurl"; body })
    | ["storyboard"; filename] ->
      (match Stream.Source.storyboard source with
       | None -> Error Not_found
       | Some sb ->
         let id =
           String.chop_suffix_exn filename ~suffix:".jpg"
           |> Int.of_string
         in
         let body = Stream.Storyboard.fetch sb ~id in
         Ok { content_type = "image/jpeg"; body })
    | [r; "media.m3u8"] ->
      let* rendition = parse_rendition r in
      let body = Stream.Source.media source ~base_url ~rendition ~profile in
      Ok { content_type = "application/vnd.apple.mpegurl"; body }
    | [r; init] when String.is_prefix init ~prefix:"init." ->
      let* rendition = parse_rendition r in
      let container = Stream.Source.container source ~rendition in
      let body = Stream.Source.init_segment source ~rendition in
      Ok { content_type = mime_of ~rendition ~container; body }
    | [r; "seg"; seg_file] ->
      let* rendition = parse_rendition r in
      let* id = parse_seg seg_file in
      let container = Stream.Source.container source ~rendition in
      let segment = Stream.Source.segment source ~rendition ~id in
      Ok { content_type = mime_of ~rendition ~container; body = segment.data }
    | _ -> Error Not_found

let recreate_content t =
  (match t.content with
   | Some (Stream s) -> (try Stream.Source.close s with _ -> ())
   | _ -> ());
  t.content <- None;
  Log.info (fun m -> m "session %s: source invalidated, will recreate on next request" t.id)

let rec handle_request t ~path =
  match t.closed with
  | true -> Error (Unavailable "session stopped")
  | false ->
    try serve t ~path with
    | exn when t.retries_remaining > 0 ->
      Log.info (fun m -> m "session %s: error: %s; recreating" t.id (Exn.to_string exn));
      t.retries_remaining <- t.retries_remaining - 1;
      recreate_content t;
      handle_request t ~path
    | exn ->
      Log.err (fun m -> m "session %s: permanent failure: %s" t.id (Exn.to_string exn));
      stop t;
      Error (Unavailable (Exn.to_string exn))

(* ── Lifecycle ─────────────────────────────────────────────────── *)

let start_activity_monitor ~sw t =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let interval = Float.min t.ttl 60.0 in
    let rec loop () =
      Eio.Time.sleep t.clock interval;
      let idle = Eio.Time.now t.clock -. t.last_accessed_at in
      match Float.(idle > t.ttl) with
      | true ->
        Log.info (fun m -> m "session %s idle (%.0fs > %.0fs); stopping"
                    t.id idle t.ttl);
        stop t;
        `Stop_daemon
      | false -> loop ()
    in
    loop ())

let start_sink_monitor ~sw t =
  match Sink.terminated t.sink with
  | None -> ()
  | Some p ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Promise.await p;
      Log.info (fun m -> m "playback ended; stopping session %s" t.id);
      stop t;
      `Stop_daemon)

let run t ~on_terminate =
  Exn.protect ~finally:on_terminate ~f:(fun () ->
    match
      Eio.Switch.run (fun sw ->
        Eio.Switch.on_release sw (fun () -> close t);
        t.sw <- Some sw;
        let content = ensure_content t in
        t.sink <- t.sink_factory ~sw ~content;
        start_activity_monitor ~sw t;
        start_sink_monitor ~sw t;
        Eio.Fiber.await_cancel ())
    with
    | () -> ()
    | exception exn ->
      let msg = Exn.to_string exn in
      match String.is_substring msg ~substring:"session stopped" with
      | true -> ()
      | false ->
        Log.err (fun m -> m "session %s failed: %s" t.id msg))
