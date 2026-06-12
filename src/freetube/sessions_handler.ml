open! Base
open Session
open Devices
open Util

module Log = (val Log_src.src_log ~doc:"Session control endpoints" Stdlib.__MODULE__)

type id_request = { session_id : string } [@@deriving of_yojson]

type seek_request = {
  session_id : string;
  seconds : float;
} [@@deriving of_yojson]

type seek_path_request = { seconds : float } [@@deriving of_yojson]

(* Shared wire types live in [Api.Session_api]. *)
open Api.Session_api

let default_video_codecs : Codec.Video.t list =
  [ Av1; Hevc; Vp9; Avc ]

let default_audio_codecs : Codec.Audio.t list =
  [ Opus; Aac; Flac ]

let respond_string body =
  Response.ok body

let respond_json payload =
  Response.ok ~content_type:(Explicit "application/json")
    (Yojson.Safe.to_string payload)

let sink_error_error (e : Sink.error) =
  match e with
  | Not_controllable -> `Conflict "sink not controllable"
  | Airplay_error (Auth_failed _) -> `Unauthorized (Sink.error_to_string e)
  | Airplay_error _ | Dlna_error _ -> `Upstream_error (Sink.error_to_string e)

let host_of_request ~(app : _ App.t) request =
  match request.Request.host with
  | Host h when not (String.is_empty h) ->
      (match String.lsplit2 h ~on:':' with
       | Some (host, _) -> host, app.port
       | None -> h, app.port)
  | Host _ -> "127.0.0.1", app.port
  | No_host ->
      (match request.client with
       | Unknown_client -> "127.0.0.1", app.port
       | Peer client_address ->
           let host = Local_ip.for_peer ~net:(Eio.Stdenv.net app.env) client_address in
           let host_str =
             Eio.Net.Ipaddr.fold host
               ~v4:(fun _ -> Stdlib.Format.asprintf "%a" Eio.Net.Ipaddr.pp host)
               ~v6:(fun _ -> Stdlib.Format.asprintf "[%a]" Eio.Net.Ipaddr.pp host)
           in
           host_str, app.port)

let manifest_url_for ~(app : _ App.t) ~session_id ~request
      ~stream_format =
  let host, port = host_of_request ~app request in
  match stream_format with
  | Api.Stream_format.Hls  -> Printf.sprintf "http://%s:%d/sessions/%s/master.m3u8" host port session_id
  | Dash -> Printf.sprintf "http://%s:%d/sessions/%s/dash.mpd" host port session_id

let summary_of ~clock session =
  let id = Session.id session in
  let created_at = Session.created_at session in
  let idle_seconds =
    Eio.Time.now clock -. Session.last_accessed_at session
  in
  let sink = Session.sink session in
  {
    session_id = id;
    created_at;
    idle_seconds;
    sink = {
      kind = Sink.kind_to_string (Sink.kind sink);
      friendly_name = Sink.friendly_name sink;
      controllable = Sink.controllable sink;
    };
  }

let content_url_for ~net ~peer_address ~peer_port ~server_port ~filename =
  match String.is_prefix filename ~prefix:"http://"
        || String.is_prefix filename ~prefix:"https://" with
  | true -> filename
  | false ->
      let local_ip =
        Local_ip.for_address ~net ~address:peer_address ~port:peer_port
      in
      Printf.sprintf "http://%s:%d/%s" local_ip server_port filename

let content_url_for_entry ~(app : _ App.t) ~filename (entry : Device.t) =
  let net = Eio.Stdenv.net app.env in
  match entry.client with
  | Device.Client.Airplay a ->
      content_url_for ~net ~peer_address:a.address ~peer_port:a.port
        ~server_port:app.port ~filename
  | Dlna d ->
      let uri = Uri.of_string d.control_url in
      let peer_address = Uri.host uri |> Option.value ~default:d.address in
      let peer_port = Uri.port uri |> Option.value ~default:80 in
      content_url_for ~net ~peer_address ~peer_port ~server_port:app.port
        ~filename
  | Url -> failwith "content_url_for_entry: Url device has no peer"

(* Construct a sink for a given device entry. Returns the sink and a
   content URL helper that resolves filenames against that device's
   network locus. *)
let sink_of_device ~env ~sw ~(app : _ App.t) ~filename ~title
      ?duration_seconds ?resolution ?(is_live = false)
      (entry : Device.t) : Sink.t * string =
  let content_url = content_url_for_entry ~app ~filename entry in
  match entry.client with
  | Device.Client.Airplay device ->
      Sink.airplay ~env ~sw ~device
        ~vendor:entry.vendor
        ~ntp:app.ntp, content_url
  | Dlna client ->
      let mime =
        match Dlna_protocol.Mime.of_filename filename with
        | Some m -> m
        | None -> Printf.failwithf "Unsupported file type: %s" filename ()
      in
      Sink.dlna ~env ~sw
        ~client
        ~title ~mime
        ~vendor:entry.vendor
        ?duration_seconds ?resolution ~is_live (),
      content_url
  | Url -> failwith "sink_of_device: Url device has no sink"

let sink_label session =
  match Sink.kind (Session.sink session) with
  | `Airplay -> "AirPlay"
  | `Dlna    -> "DLNA"
  | `Url     -> "URL"

let with_session_body ~action ~(app : _ App.t) request f =
  let ( let* ) result f = Result.bind result ~f in
  let* body = Json_io.parse_body ~context:action id_request_of_yojson request in
  match Sessions.find app.sessions ~id:body.session_id with
  | None -> Error `Not_found
  | Some session ->
      let context = Printf.sprintf "%s %s" (sink_label session) action in
      match f session with
      | Ok () -> Ok (respond_string "OK")
      | Error e ->
          let msg = Printf.sprintf "%s: %s" context (Sink.error_to_string e) in
          (match sink_error_error e with
           | `Conflict _ -> Error (`Conflict msg)
           | `Unauthorized _ -> Error (`Unauthorized msg)
           | `Upstream_error _ -> Error (`Upstream_error msg)
           | _ -> Error (`Internal_error msg))

let handle_pause ~(app : _ App.t) request =
  with_session_body ~action:"pause" ~app request (fun s ->
    Sink.pause (Session.sink s))

let handle_resume ~(app : _ App.t) request =
  with_session_body ~action:"resume" ~app request (fun s ->
    Sink.resume (Session.sink s))

let handle_seek ~(app : _ App.t) request =
  let ( let* ) result f = Result.bind result ~f in
  let* body = Json_io.parse_body ~context:"Seek" seek_request_of_yojson request in
  match Sessions.find app.sessions ~id:body.session_id with
  | None -> Error `Not_found
  | Some session ->
      let context = Printf.sprintf "%s seek" (sink_label session) in
      match Sink.seek (Session.sink session) ~seconds:body.seconds with
      | Ok () -> Ok (respond_string "OK")
      | Error e ->
          let msg = Printf.sprintf "%s: %s" context (Sink.error_to_string e) in
          (match sink_error_error e with
           | `Conflict _ -> Error (`Conflict msg)
           | `Unauthorized _ -> Error (`Unauthorized msg)
           | `Upstream_error _ -> Error (`Upstream_error msg)
           | _ -> Error (`Internal_error msg))

let handle_close ~(app : _ App.t) request =
  let ( let* ) result f = Result.bind result ~f in
  let* body = Json_io.parse_body ~context:"Close session" id_request_of_yojson request in
  (match Sessions.find app.sessions ~id:body.session_id with
   | Some session -> Session.stop session
   | None -> ());
  Ok (respond_string "OK")

let handle_player_page ~(app : _ App.t) =
  let sessions = Sessions.list app.sessions in
  let links =
    List.map sessions ~f:(fun session ->
      let id = Session.id session in
      let hls = Printf.sprintf "/sessions/%s/master.m3u8" id in
      let dash = Printf.sprintf "/sessions/%s/dash.mpd" id in
      Printf.sprintf
        "<li><b>%s</b> — <a href=\"%s\">HLS</a> | <a href=\"%s\">DASH</a></li>" id hls dash)
    |> String.concat ~sep:"\n"
  in
  let body = Printf.sprintf
    "<!DOCTYPE html><html><head><title>FreeTube streams</title></head>\
     <body><h1>Active streams</h1><ul>%s</ul></body></html>" links
  in
  Ok (Response.ok ~content_type:(Explicit "text/html") body)

let handle_list ~(app : _ App.t) =
  let clock = Eio.Stdenv.clock app.env in
  let payload =
    sessions_response_to_yojson
      { sessions =
          List.map (Sessions.list app.sessions)
            ~f:(summary_of ~clock) }
  in
  Ok (respond_json payload)

(* ── New REST endpoints under /sessions/<id> ───────────────────── *)

let handle_get_session ~(app : _ App.t) ~id =
  match Sessions.find app.sessions ~id with
  | None -> Error `Not_found
  | Some session ->
      let clock = Eio.Stdenv.clock app.env in
      Ok (respond_json (session_summary_to_yojson (summary_of ~clock session)))

let respond_playlist ~body =
  Response.ok ~content_type:(Explicit "application/vnd.apple.mpegurl")
    ~headers:
      [ "cache-control", "no-store";
        "transferMode.dlna.org", "Streaming" ]
    body

let respond_media ~content_type ~body ~accept_ranges =
  let accept_ranges =
    match accept_ranges with
    | true -> Response.Allow_ranges
    | false -> Response.No_ranges
  in
  Response.ok ~content_type:(Explicit content_type) ~accept_ranges body

let handle_session_request ~(app : _ App.t) ~id ~sub_path (_request : Request.t) =
  match Sessions.find app.sessions ~id with
  | None -> Error `Not_found
  | Some session ->
    let path_str = Routes.Parts.wildcard_match sub_path in
    match String.is_empty path_str with
    | true ->
      let clock = Eio.Stdenv.clock app.env in
      Ok (respond_json (session_summary_to_yojson (summary_of ~clock session)))
    | false ->
      Session.touch session;
      let path =
        String.split path_str ~on:'/'
        |> List.filter ~f:(fun s -> not (String.is_empty s))
      in
      match Session.handle_request session ~path with
      | Ok { content_type; body; accept_ranges } ->
        Ok (respond_media ~content_type ~body ~accept_ranges)
      | Error Not_found -> Error `Not_found
      | Error No_stream -> Error (`Conflict "no stream source")
      | Error (Unavailable msg) -> Error (`Upstream_error msg)

let handle_delete_session ~(app : _ App.t) ~id =
  match Sessions.find app.sessions ~id with
  | None -> Ok (Response.no_content ())
  | Some session ->
      Session.stop session;
      Ok (Response.no_content ())

let with_controllable_sink ~(app : _ App.t) ~id ~action f =
  match Sessions.find app.sessions ~id with
  | None -> Error `Not_found
  | Some session ->
      let sink = Session.sink session in
      match Sink.controllable sink with
      | false ->
          Error (`Conflict (Printf.sprintf "%s: sink not controllable" action))
      | true ->
          match f sink with
          | Ok () -> Ok (respond_string "OK")
          | Error e ->
              let msg =
                Printf.sprintf "%s %s: %s" (sink_label session) action
                  (Sink.error_to_string e)
              in
              (match sink_error_error e with
               | `Conflict _ -> Error (`Conflict msg)
               | `Unauthorized _ -> Error (`Unauthorized msg)
               | `Upstream_error _ -> Error (`Upstream_error msg)
               | _ -> Error (`Internal_error msg))

let handle_post_pause ~(app : _ App.t) ~id =
  with_controllable_sink ~app ~id ~action:"pause" Sink.pause

let handle_post_resume ~(app : _ App.t) ~id =
  with_controllable_sink ~app ~id ~action:"resume" Sink.resume

let handle_post_seek ~(app : _ App.t) ~id request =
  let ( let* ) result f = Result.bind result ~f in
  let* body = Json_io.parse_body ~context:"Seek" seek_path_request_of_yojson request in
  with_controllable_sink ~app ~id ~action:"seek" (fun sink ->
      Sink.seek sink ~seconds:body.seconds)

(* ── POST /sessions (create) ───────────────────────────────────── *)

let video_codec_of_string s =
  match String.lowercase s with
  | "av1"  -> Ok Codec.Video.Av1
  | "hevc" -> Ok Codec.Video.Hevc
  | "vp9"  -> Ok Codec.Video.Vp9
  | "avc"  -> Ok Codec.Video.Avc
  | _ -> Error (`Bad_param (Printf.sprintf "unknown video codec: %s" s))

let audio_codec_of_string s =
  match String.lowercase s with
  | "opus" -> Ok Codec.Audio.Opus
  | "aac"  -> Ok Codec.Audio.Aac
  | "flac" -> Ok Codec.Audio.Flac
  | "vorbis" -> Ok Codec.Audio.Vorbis
  | _ -> Error (`Bad_param (Printf.sprintf "unknown audio codec: %s" s))

let parse_codec_list decode strs =
  let ( let* ) result f = Result.bind result ~f in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | x :: xs ->
        let* value = decode x in
        loop (value :: acc) xs
  in
  loop [] strs

let device_codecs (entry : Device.t) =
  entry.video_codecs, entry.audio_codecs

(* Effective codecs: request override > sink device > defaults. *)
let effective_codecs ~entry ~vcodecs ~acodecs =
  let device_v, device_a =
    Option.value_map entry ~default:(None, None)
      ~f:(fun e -> let v, a = device_codecs e in Some v, Some a)
  in
  let video =
    match vcodecs with
    | Some xs -> parse_codec_list video_codec_of_string xs
    | None -> Ok (Option.value device_v ~default:default_video_codecs)
  in
  let audio =
    match acodecs with
    | Some xs -> parse_codec_list audio_codec_of_string xs
    | None -> Ok (Option.value device_a ~default:default_audio_codecs)
  in
  match video, audio with
  | Ok v, Ok a -> Ok (v, a)
  | Error err, _ -> Error err
  | _, Error err -> Error err

let handle_create_body ~(app : _ App.t) ~env ~clock
      ~session_id request =
  let ( let* ) result f = Result.bind result ~f in
  let* body = Json_io.parse_body ~context:"Create session" create_request_of_yojson request in
  let* entry =
    match body.sink with
    | None -> Ok None
    | Some device_id ->
        match Device_store.find app.device_store ~id:device_id with
        | Some e -> Ok (Some e)
        | None -> Error `Not_found
  in
  let* () =
    match body.source, entry with
    | Url _, None -> Error (`Bad_param "Create session: source 'url' requires a sink device")
    | _ -> Ok ()
  in
  let* video_codecs, audio_codecs =
    effective_codecs ~entry ~vcodecs:body.vcodecs ~acodecs:body.acodecs
  in
  let stream_format =
    match body.stream_format, entry with
    | Some f, _ -> f
    | None, Some e -> e.stream_format
    | None, None -> Api.Stream_format.Hls
  in
  let transcode =
    let transcode =
      match entry with
      | Some e -> e.transcode
      | None -> not (List.mem video_codecs Codec.Video.Av1 ~equal:Codec.Video.equal)
    in
    transcode && (Config.get ()).transcode
  in
  let max_width =
    match entry with
    | Some e -> e.max_width
    | None -> (Config.get ()).video.max_width
  in
  let max_height =
    match entry with
    | Some e -> e.max_height
    | None -> (Config.get ()).video.max_height
  in
  let content_factory =
    match body.source with
    | Youtube_id id ->
      Log.info (fun m -> m "create session for youtube_id=%s (cookies=%d)"
                   id (Option.value_map body.cookies ~default:0 ~f:List.length));
      let cookies = Option.value body.cookies ~default:[] in
      fun ~sw ->
        let fetch = Youtube.Fetcher.of_yt_dlp ~env ~cookies ~video_id:id in
        let youtube = Youtube.init fetch in
        Session.Stream (Stream.Source.init ~env ~sw ~video_codecs ~audio_codecs ~max_width ~max_height ~transcode youtube)
    | Youtube_file uri ->
      Log.info (fun m -> m "create session from url=%s" (Uri.to_string uri));
      fun ~sw ->
        let fetch = Youtube.Fetcher.of_url ~env ~sw uri in
        let youtube = Youtube.init fetch in
        Session.Stream (Stream.Source.init ~env ~sw ~video_codecs ~audio_codecs ~max_width ~max_height ~transcode youtube)
    | Url uri ->
      fun ~sw:_ -> Session.Direct uri
  in
  let user_master_url =
    match body.source with
    | Url uri -> Uri.to_string uri
    | Youtube_id _ | Youtube_file _ ->
        manifest_url_for ~app ~session_id ~request ~stream_format
  in
  let* () =
    match entry with
    | Some { client = Device.Client.Airplay client; _ } ->
        (match Sink.probe_airplay ~env ~client with
         | Ok () -> Ok ()
         | Error `No_credentials ->
             Error (`Unauthorized
               (Printf.sprintf "No stored AirPlay credentials for %s (pair first)"
                  (Airplay.Client.friendly_name client)))
         | Error (`Invalid_credentials msg) -> Error (`Unauthorized msg)
         | Error (`Unavailable msg) -> Error (`Upstream_error msg))
    | _ -> Ok ()
  in
  let sink_factory =
    match entry with
    | None -> fun ~sw:_ ~content:_ -> Sink.Url_consumer
    | Some e ->
      let sink_filename =
        match body.source, e.stream_format with
        | Url uri, _ -> Uri.to_string uri
        | (Youtube_id _ | Youtube_file _), Api.Stream_format.Hls ->
            Printf.sprintf "sessions/%s/master.m3u8" session_id
        | (Youtube_id _ | Youtube_file _), Dash ->
            Printf.sprintf "sessions/%s/dash.mpd" session_id
      in
      fun ~sw ~content ->
        let title, duration_seconds, resolution, is_live =
          match content with
          | Session.Stream source ->
              Stream.Source.title source,
              Some (Stream.Source.duration_seconds source),
              Stream.Source.resolution source,
              Stream.Source.is_live source
          | Direct _ -> "FreeTube", None, None, false
        in
        let sink, content_url =
          sink_of_device ~env ~sw ~app ~filename:sink_filename ~title
            ?duration_seconds ?resolution ~is_live e
        in
        (match Sink.play sink ~url:content_url with
         | Ok () -> sink
         | Error err -> failwith (Sink.error_to_string err))
  in
  let session =
    Session.init ~id:session_id ~clock ~ttl:app.global.session_ttl_seconds
      ~content_factory ~sink_factory
  in
  Sessions.add app.sessions session;
  Eio.Fiber.fork ~sw:app.sw (fun () ->
    Session.run session
      ~on_terminate:(fun () -> Sessions.remove app.sessions ~id:session_id));
  Ok (respond_json (create_response_to_yojson { session_id; url = user_master_url }))

let handle_create ~(app : _ App.t) request =
  let env = app.env in
  let clock = Eio.Stdenv.clock env in
  let session_id = Uuid.v4 () in
  match
    handle_create_body ~app ~env ~clock
      ~session_id request
  with
  | response -> response
  | exception exn ->
      Sessions.remove app.sessions ~id:session_id;
      Error (`Internal_error (Exn.to_string exn))

(* ── Tests ─────────────────────────────────────────────────────── *)

let%expect_test "effective_codecs: defaults when nothing supplied" =
  (match effective_codecs ~entry:None ~vcodecs:None ~acodecs:None with
   | Ok (v, a) ->
       Stdlib.Printf.printf "v=%s a=%s\n"
         (String.concat ~sep:"," (List.map v ~f:Codec.Video.to_string))
         (String.concat ~sep:"," (List.map a ~f:Codec.Audio.to_string))
   | Error (`Bad_param msg) -> Stdlib.print_endline msg);
  [%expect {| v=av1,hevc,vp9,avc a=opus,aac,flac |}]

let%expect_test "effective_codecs: device when no override" =
  let entry : Device.t = {
    id = "x"; friendly_name = "tv"; vendor = Vendor.Generic;
    stream_format = Api.Stream_format.Hls;
    transcode = false;
    max_width = 3840; max_height = 2160;
    video_codecs = [ Codec.Video.Avc ];
    audio_codecs = [ Codec.Audio.Aac ];
    client = Airplay {
      name = "n"; fn = Some "tv"; address = "1"; port = 7000;
      pairing_id = "p"; public_key = None;
      features = None; flags = None; model = None; txt = [];
    }
  } in
  (match effective_codecs ~entry:(Some entry) ~vcodecs:None ~acodecs:None with
   | Ok (v, a) ->
       Stdlib.Printf.printf "v=%s a=%s\n"
         (String.concat ~sep:"," (List.map v ~f:Codec.Video.to_string))
         (String.concat ~sep:"," (List.map a ~f:Codec.Audio.to_string))
   | Error (`Bad_param msg) -> Stdlib.print_endline msg);
  [%expect {| v=avc a=aac |}]

let%expect_test "effective_codecs: request overrides device" =
  let entry : Device.t = {
    id = "x"; friendly_name = "tv"; vendor = Vendor.Generic;
    stream_format = Api.Stream_format.Hls;
    transcode = false;
    max_width = 3840; max_height = 2160;
    video_codecs = [ Codec.Video.Avc ];
    audio_codecs = [ Codec.Audio.Aac ];
    client = Airplay {
      name = "n"; fn = Some "tv"; address = "1"; port = 7000;
      pairing_id = "p"; public_key = None;
      features = None; flags = None; model = None; txt = [];
    }
  } in
  (match effective_codecs ~entry:(Some entry)
           ~vcodecs:(Some ["hevc"]) ~acodecs:None with
   | Ok (v, a) ->
       Stdlib.Printf.printf "v=%s a=%s\n"
         (String.concat ~sep:"," (List.map v ~f:Codec.Video.to_string))
         (String.concat ~sep:"," (List.map a ~f:Codec.Audio.to_string))
   | Error (`Bad_param msg) -> Stdlib.print_endline msg);
  [%expect {| v=hevc a=aac |}]

let%expect_test "effective_codecs: rejects unknown codec" =
  (match effective_codecs ~entry:None
           ~vcodecs:(Some ["bogus"]) ~acodecs:None with
   | Ok _ -> Stdlib.print_endline "ok?"
   | Error (`Bad_param e) -> Stdlib.print_endline e);
  [%expect {| unknown video codec: bogus |}]
