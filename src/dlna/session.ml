module Err = Error
open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA high-level playback" Stdlib.__MODULE__)

(* Run a control flow that may raise at the network boundary, folding any
   such exception into a recoverable [Err.Network]. The flow itself yields an
   [Err.t Result.t] for action-level (non-200) failures. *)
let in_monad f =
  match Result.try_with f with
  | Ok result -> result
  | Error exn -> Error (Err.Network (Exn.to_string exn))

let soap_post ~client ~control_url ~body ~headers =
  let uri = Uri.of_string control_url in
  let content_type =
    List.find_map headers ~f:(fun (k, v) ->
      match String.equal (String.lowercase k) "content-type" with
      | true -> Some v
      | false -> None)
  in
  let other_headers =
    List.filter headers ~f:(fun (k, _) ->
      not (String.equal (String.lowercase k) "content-type"))
  in
  let response =
    Http_client.post client ~ip_version:`V4 ~headers:other_headers ?content_type ~oneshot:true ~body uri
  in
  response.status, response.body

let send_stop ~client ~control_url =
  let body, headers = Av_transport.stop ~control_url in
  let status, payload = soap_post ~client ~control_url ~body ~headers in
  Log.debug (fun m -> m "Stop returned %d: %s" status payload)

(* Surface the renderer's SOAP fault so non-200 responses are diagnosable. *)
let log_action_failure ~action ~status ~payload =
  let detail =
    match Av_transport.parse_upnp_error payload with
    | Some { error_code; error_description } ->
        Printf.sprintf "UPnP error %d: %s" error_code error_description
    | None -> payload
  in
  Log.warn (fun m -> m "%s failed (HTTP %d): %s" action status detail)

let string_of_state = function
  | Av_transport.Playing -> "PLAYING"
  | Stopped -> "STOPPED"
  | Paused -> "PAUSED"
  | Transitioning -> "TRANSITIONING"
  | No_media -> "NO_MEDIA"

let get_transport_state ~client ~control_url =
  let body, headers = Av_transport.get_transport_info ~control_url in
  let status, payload = soap_post ~client ~control_url ~body ~headers in
  match status with
  | 200 ->
      let state = Av_transport.parse_transport_state payload in
      Log.debug (fun m ->
        m "GetTransportInfo -> %s"
          (match state with
           | Ok s -> string_of_state s
           | Error e -> Printf.sprintf "parse-error:%s" e.error_description));
      Result.ok state
  | _ ->
      Log.debug (fun m -> m "GetTransportInfo returned HTTP %d" status);
      None

let current_track_uri ~client ~control_url =
  let body, headers = Av_transport.get_position_info ~control_url in
  let status, payload = soap_post ~client ~control_url ~body ~headers in
  match status with
  | 200 ->
      (match Av_transport.parse_position_info payload with
       | Ok { track_uri; _ } -> Some track_uri
       | Error _ -> None)
  | _ -> None

(* Poll GetTransportInfo while the renderer is TRANSITIONING and return the
   first definitive state. TRANSITIONING is not a confirmation of playback: a
   renderer may sit there while eagerly caching, so callers must wait for it to
   resolve to PLAYING (or another terminal state) before drawing a conclusion. *)
let await_settled ~attempts ~clock ~client ~control_url () =
  let rec loop attempts =
    match get_transport_state ~client ~control_url with
    | Some Av_transport.Transitioning when attempts > 0 ->
        Eio.Time.sleep clock 5.0;
        loop (attempts - 1)
    | other -> other
  in
  loop attempts

(* UPnP AVTransport error 701 = "Transition not available": the renderer
   rejects Play because it is already playing. Treat as success. *)
let send_play ~client ~control_url =
  let body, headers = Av_transport.play ~control_url in
  let status, payload = soap_post ~client ~control_url ~body ~headers in
  match status with
  | 200 -> Ok ()
  | _ ->
      let upnp = Av_transport.parse_upnp_error payload in
      Log.info (fun m ->
        m "Play returned HTTP %d%s" status
          (match upnp with
           | Some e -> Printf.sprintf " (UPnP %d: %s)" e.error_code e.error_description
           | None -> ""));
      (match upnp with
       | Some { error_code = 701; _ } -> Ok ()
       | _ -> Error status)

(* The renderer's reply to Play is unreliable (LG faults while already
   buffering/playing), so we fire Play and accept playback regardless of the
   result. We still skip Play if the renderer already auto-played. *)
let ensure_playing ~clock ~client ~control_url =
  match await_settled ~attempts:60 ~clock ~client ~control_url () with
  | Some Av_transport.Playing ->
      Log.info (fun m -> m "renderer auto-played; skipping explicit Play");
      Ok ()
  | _ ->
      (match send_play ~client ~control_url with
       | Ok () -> ()
       | Error status ->
           Log.info (fun m -> m "Play returned error %d; ignoring" status));
      Ok ()

let play ~clock ~client ~control_url ~content_url ~title ~mime
      ~duration_seconds ~resolution ~is_live =
  in_monad (fun () ->
    let metadata =
      Didl_lite.generate
        { title; mime_type = mime; url = content_url;
          duration_seconds; resolution; is_live }
    in
    send_stop ~client ~control_url;
    let body, headers =
      Av_transport.set_av_transport_uri ~control_url ~uri:content_url ~metadata
    in
    let status, payload = soap_post ~client ~control_url ~body ~headers in
    match status with
    | 200 -> ensure_playing ~clock ~client ~control_url
    | _ ->
        log_action_failure ~action:"SetAVTransportURI" ~status ~payload;
        Error (Err.Action_failed { action = "SetAVTransportURI"; status }))

let send_action ~client ~control_url ~name ~body ~headers =
  in_monad (fun () ->
    let status, payload = soap_post ~client ~control_url ~body ~headers in
    Log.debug (fun m -> m "%s returned %d: %s" name status payload);
    match status with
    | 200 -> Ok ()
    | _ -> Error (Err.Action_failed { action = name; status }))

let pause ~client ~control_url =
  let body, headers = Av_transport.pause ~control_url in
  send_action ~client ~control_url ~name:"Pause" ~body ~headers

let resume ~client ~control_url =
  let body, headers = Av_transport.play ~control_url in
  send_action ~client ~control_url ~name:"Resume" ~body ~headers

let format_seek_target seconds =
  let total = Float.to_int seconds in
  let h = total / 3600 in
  let m = (total / 60) % 60 in
  let s = total % 60 in
  Printf.sprintf "%d:%02d:%02d" h m s

let seek ~client ~control_url ~seconds =
  let target = format_seek_target seconds in
  let body, headers = Av_transport.seek ~control_url ~target in
  send_action ~client ~control_url ~name:"Seek" ~body ~headers

let stop ~client ~control_url =
  let body, headers = Av_transport.stop ~control_url in
  send_action ~client ~control_url ~name:"Stop" ~body ~headers

type t = {
  http : Http_client.t;
  control_url : string;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  sw : Eio.Switch.t;
  terminated_promise : unit Eio.Promise.t;
  terminated_resolver : unit Eio.Promise.u;
}

let connect ~env ~sw ~client =
  let http =
    Http_client.init
      ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
      ~sw ~env ()
  in
  let terminated_promise, terminated_resolver = Eio.Promise.create () in
  { http; control_url = Dlna.Client.control_url client;
    clock = Eio.Stdenv.clock env;
    sw;
    terminated_promise;
    terminated_resolver }

(* Report what the renderer is doing with respect to our stream. [`Stopped ours]
   carries whether the renderer's current track URI still matches [content_url],
   so callers can distinguish our stream ending from the renderer having moved
   on to something else. *)
let playback_status t ~content_url =
  match get_transport_state ~client:t.http ~control_url:t.control_url with
  | Some (Av_transport.Playing | Transitioning | Paused) -> `Active
  | Some (Stopped | No_media) ->
      let ours =
        match current_track_uri ~client:t.http ~control_url:t.control_url with
        | Some uri -> String.equal uri content_url
        | None -> false
      in
      `Stopped ours
  | None -> `Unknown

let start_monitor t ~content_url =
  Eio.Fiber.fork ~sw:t.sw (fun () ->
    let rec loop seen_active =
      Eio.Time.sleep t.clock 10.0;
      match playback_status t ~content_url with
      | `Active -> loop true
      | `Unknown -> loop seen_active
      | `Stopped _ when not seen_active -> loop seen_active
      | `Stopped _ ->
          Log.info (fun m -> m "renderer stopped playing");
          ignore (Eio.Promise.try_resolve t.terminated_resolver () : bool)
    in
    try loop false
    with Eio.Cancel.Cancelled _ -> ())

let play t ~content_url ~title ~mime ~duration_seconds ~resolution ~is_live =
  match
    play ~clock:t.clock ~client:t.http ~control_url:t.control_url
      ~content_url ~title ~mime ~duration_seconds ~resolution ~is_live
  with
  | Ok () ->
      start_monitor t ~content_url;
      Ok ()
  | Error _ as err -> err

let pause t = pause ~client:t.http ~control_url:t.control_url
let resume t = resume ~client:t.http ~control_url:t.control_url
let seek t ~seconds = seek ~client:t.http ~control_url:t.control_url ~seconds
let stop t = stop ~client:t.http ~control_url:t.control_url

let terminated t = t.terminated_promise
