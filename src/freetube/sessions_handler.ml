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

let respond_string = Json_io.respond_string
let respond_json = Json_io.respond_json

let sink_error_status (e : Sink.error) : Piaf.Status.t =
  match e with
  | Not_controllable -> `Conflict
  | Airplay_error (Auth_failed _) -> `Unauthorized
  | Airplay_error _ | Dlna_error _ -> `Bad_gateway

let producer_status (e : Stream.Producer.Error.t) : Piaf.Status.t =
  match e with
  | Source_unavailable _ -> `Bad_gateway
  | Parse_error _        -> `Bad_gateway
  | Codec_unsupported _  -> `Unsupported_media_type
  | Aborted              -> `Service_unavailable

let host_of_request ~(app : _ App.t) ~client_address request =
  match Piaf.Headers.get request.Piaf.Request.headers "host" with
  | Some h when not (String.is_empty h) ->
      (match String.lsplit2 h ~on:':' with
       | Some (host, _) -> host, app.port
       | None -> h, app.port)
  | _ ->
      let host = Local_ip.for_peer client_address in
      let host_str =
        Eio.Net.Ipaddr.fold host
          ~v4:(fun _ -> Stdlib.Format.asprintf "%a" Eio.Net.Ipaddr.pp host)
          ~v6:(fun _ -> Stdlib.Format.asprintf "[%a]" Eio.Net.Ipaddr.pp host)
      in
      host_str, app.port

let manifest_url_for ~(app : _ App.t) ~client_address ~session_id ~request
      ~stream_format =
  let host, port = host_of_request ~app ~client_address request in
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

let content_url_for ~peer_address ~peer_port ~server_port ~filename =
  match String.is_prefix filename ~prefix:"http://"
        || String.is_prefix filename ~prefix:"https://" with
  | true -> filename
  | false ->
      let local_ip = Local_ip.for_address ~address:peer_address ~port:peer_port in
      Printf.sprintf "http://%s:%d/%s" local_ip server_port filename

let content_url_for_entry ~(app : _ App.t) ~filename (entry : Device.t) =
  match entry.client with
  | Device.Client.Airplay a ->
      content_url_for ~peer_address:a.address ~peer_port:a.port
        ~server_port:app.port ~filename
  | Dlna d ->
      let uri = Uri.of_string d.control_url in
      let peer_address = Uri.host uri |> Option.value ~default:d.address in
      let peer_port = Uri.port uri |> Option.value ~default:80 in
      content_url_for ~peer_address ~peer_port ~server_port:app.port ~filename
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
  let body = Json_io.parse_body ~context:action id_request_of_yojson request in
  match Sessions.find app.sessions ~id:body.session_id with
  | None ->
      Json_io.raise_http `Not_found
        (Printf.sprintf "%s: session %s not found" action body.session_id)
  | Some session ->
      let context = Printf.sprintf "%s %s" (sink_label session) action in
      match f session with
      | Ok () -> respond_string ~status:`OK "OK"
      | Error e ->
          respond_string ~status:(sink_error_status e)
            (Printf.sprintf "%s: %s" context (Sink.error_to_string e))

let handle_pause ~(app : _ App.t) request =
  with_session_body ~action:"pause" ~app request (fun s ->
    Sink.pause (Session.sink s))

let handle_resume ~(app : _ App.t) request =
  with_session_body ~action:"resume" ~app request (fun s ->
    Sink.resume (Session.sink s))

let handle_seek ~(app : _ App.t) request =
  let body = Json_io.parse_body ~context:"Seek" seek_request_of_yojson request in
  match Sessions.find app.sessions ~id:body.session_id with
  | None ->
      Json_io.raise_http `Not_found
        (Printf.sprintf "Seek: session %s not found" body.session_id)
  | Some session ->
      let context = Printf.sprintf "%s seek" (sink_label session) in
      match Sink.seek (Session.sink session) ~seconds:body.seconds with
      | Ok () -> respond_string ~status:`OK "OK"
      | Error e ->
          respond_string ~status:(sink_error_status e)
            (Printf.sprintf "%s: %s" context (Sink.error_to_string e))

let handle_close ~(app : _ App.t) request =
  let body = Json_io.parse_body ~context:"Close session" id_request_of_yojson request in
  (match Sessions.find app.sessions ~id:body.session_id with
   | Some session -> Session.stop session
   | None -> ());
  respond_string ~status:`OK "OK"

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
  let headers = Piaf.Headers.of_list [ "content-type", "text/html" ] in
  Piaf.Response.of_string ~headers ~body `OK

let handle_list ~(app : _ App.t) =
  let clock = Eio.Stdenv.clock app.env in
  let payload =
    sessions_response_to_yojson
      { sessions =
          List.map (Sessions.list app.sessions)
            ~f:(summary_of ~clock) }
  in
  respond_json ~status:`OK payload

(* ── New REST endpoints under /sessions/<id> ───────────────────── *)

let handle_get_session ~(app : _ App.t) ~id =
  match Sessions.find app.sessions ~id with
  | None -> respond_string ~status:`Not_found (Printf.sprintf "Session %s not found" id)
  | Some session ->
      let clock = Eio.Stdenv.clock app.env in
      respond_json ~status:`OK
        (session_summary_to_yojson (summary_of ~clock session))

let respond_playlist ~body =
  let headers =
    Piaf.Headers.of_list
      [ "content-type", "application/vnd.apple.mpegurl";
        "cache-control", "no-store";
        "content-length", Int.to_string (String.length body);
        "transferMode.dlna.org", "Streaming" ]
  in
  Piaf.Response.of_string ~headers ~body `OK

let respond_media ~content_type ~body ~accept_ranges (request : Piaf.Request.t) =
  let total = String.length body in
  let range_header = Piaf.Headers.get (Piaf.Request.headers request) "range" in
  let parsed_range =
    match accept_ranges, range_header with
    | true, Some header -> Static.parse_range header ~total
    | _ -> None
  in
  match accept_ranges, range_header, parsed_range with
  | true, Some _, None when total > 0 ->
    Static.respond_range_not_satisfiable ~total
  | _ ->
    let offset, length, status =
      match parsed_range with
      | None -> 0, total, `OK
      | Some r -> r.start, r.length, `Partial_content
    in
    let range = parsed_range in
    let headers = Static.response_headers ~content_type ~length ~range ~total in
    let body = String.sub body ~pos:offset ~len:length in
    Piaf.Response.of_string ~headers ~body status

let handle_session_request ~(app : _ App.t) ~id ~sub_path (request : Piaf.Request.t) =
  match Sessions.find app.sessions ~id with
  | None -> respond_string ~status:`Not_found (Printf.sprintf "Session %s not found" id)
  | Some session ->
    let path_str = Routes.Parts.wildcard_match sub_path in
    match String.is_empty path_str with
    | true ->
      let clock = Eio.Stdenv.clock app.env in
      respond_json ~status:`OK
        (session_summary_to_yojson (summary_of ~clock session))
    | false ->
      Session.touch session;
      let path =
        String.split path_str ~on:'/'
        |> List.filter ~f:(fun s -> not (String.is_empty s))
      in
      match Session.handle_request session ~path with
      | Ok { content_type; body; accept_ranges } ->
        respond_media ~content_type ~body ~accept_ranges request
      | Error Not_found -> respond_string ~status:`Not_found "not found"
      | Error No_stream -> respond_string ~status:`Conflict "no stream source"
      | Error (Unavailable msg) -> respond_string ~status:`Bad_gateway msg

let handle_delete_session ~(app : _ App.t) ~id =
  match Sessions.find app.sessions ~id with
  | None -> respond_string ~status:`No_content ""
  | Some session ->
      Session.stop session;
      respond_string ~status:`No_content ""

let with_controllable_sink ~(app : _ App.t) ~id ~action f =
  match Sessions.find app.sessions ~id with
  | None ->
      respond_string ~status:`Not_found
        (Printf.sprintf "%s: session %s not found" action id)
  | Some session ->
      let sink = Session.sink session in
      match Sink.controllable sink with
      | false ->
          respond_string ~status:`Conflict
            (Printf.sprintf "%s: sink not controllable" action)
      | true ->
          match f sink with
          | Ok () -> respond_string ~status:`OK "OK"
          | Error e ->
              respond_string ~status:(sink_error_status e)
                (Printf.sprintf "%s %s: %s" (sink_label session) action
                   (Sink.error_to_string e))

let handle_post_pause ~(app : _ App.t) ~id =
  with_controllable_sink ~app ~id ~action:"pause" Sink.pause

let handle_post_resume ~(app : _ App.t) ~id =
  with_controllable_sink ~app ~id ~action:"resume" Sink.resume

let handle_post_seek ~(app : _ App.t) ~id request =
  let body = Json_io.parse_body ~context:"Seek" seek_path_request_of_yojson request in
  with_controllable_sink ~app ~id ~action:"seek" (fun sink ->
    Sink.seek sink ~seconds:body.seconds)

(* ── POST /sessions (create) ───────────────────────────────────── *)

let video_codec_of_string s =
  match String.lowercase s with
  | "av1"  -> Codec.Video.Av1
  | "hevc" -> Codec.Video.Hevc
  | "vp9"  -> Codec.Video.Vp9
  | "avc"  -> Codec.Video.Avc
  | _ -> Json_io.raise_http `Bad_request (Printf.sprintf "unknown video codec: %s" s)

let audio_codec_of_string s =
  match String.lowercase s with
  | "opus" -> Codec.Audio.Opus
  | "aac"  -> Codec.Audio.Aac
  | "flac" -> Codec.Audio.Flac
  | "vorbis" -> Codec.Audio.Vorbis
  | _ -> Json_io.raise_http `Bad_request (Printf.sprintf "unknown audio codec: %s" s)

let parse_codec_list decode strs =
  List.map strs ~f:decode

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
    | None -> Option.value device_v ~default:default_video_codecs
  in
  let audio =
    match acodecs with
    | Some xs -> parse_codec_list audio_codec_of_string xs
    | None -> Option.value device_a ~default:default_audio_codecs
  in
  video, audio

let handle_create_body ~(app : _ App.t) ~env ~clock ~client_address
      ~session_id request =
  let body = Json_io.parse_body ~context:"Create session" create_request_of_yojson request in
  let entry =
    match body.sink with
    | None -> None
    | Some device_id ->
        match Device_store.find app.device_store ~id:device_id with
        | Some e -> Some e
        | None ->
            Json_io.raise_http `Not_found
              (Printf.sprintf "Create session: device %s not found" device_id)
  in
  (match body.source, entry with
   | Url _, None ->
       Json_io.raise_http `Bad_request "Create session: source 'url' requires a sink device"
   | _ -> ());
  let video_codecs, audio_codecs =
    effective_codecs ~entry ~vcodecs:body.vcodecs ~acodecs:body.acodecs
  in
  let stream_format =
    match body.stream_format with
    | Some f -> f
    | None ->
      match entry with
      | Some e -> e.stream_format
      | None -> Api.Stream_format.Hls
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
      manifest_url_for ~app ~client_address ~session_id ~request ~stream_format
  in
  (match entry with
   | Some { client = Device.Client.Airplay client; _ } ->
     (match Sink.probe_airplay ~env ~client with
      | Ok () -> ()
      | Error `No_credentials ->
        Json_io.raise_http `Unauthorized
          (Printf.sprintf "No stored AirPlay credentials for %s (pair first)"
             (Airplay.Client.friendly_name client))
      | Error (`Invalid_credentials msg) ->
        Json_io.raise_http `Unauthorized msg
      | Error (`Unavailable msg) ->
        Json_io.raise_http `Bad_gateway msg)
   | _ -> ());
  let sink_factory =
    match entry with
    | None -> fun ~sw:_ ~content:_ -> Sink.Url_consumer
    | Some e ->
      let sink_filename =
        match body.source with
        | Url uri -> Uri.to_string uri
        | Youtube_id _ | Youtube_file _ ->
          match e.stream_format with
          | Api.Stream_format.Hls  -> Printf.sprintf "sessions/%s/master.m3u8" session_id
          | Dash -> Printf.sprintf "sessions/%s/dash.mpd" session_id
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
  respond_json ~status:`OK
    (create_response_to_yojson { session_id; url = user_master_url })

let handle_create ~(app : _ App.t) ~client_address request =
  let env = app.env in
  let clock = Eio.Stdenv.clock env in
  let session_id = Uuid.v4 () in
  match
    handle_create_body ~app ~env ~clock ~client_address
      ~session_id request
  with
  | response -> response
  | exception exn ->
      Sessions.remove app.sessions ~id:session_id;
      raise exn

(* ── Tests ─────────────────────────────────────────────────────── *)

let%expect_test "effective_codecs: defaults when nothing supplied" =
  let v, a = effective_codecs ~entry:None ~vcodecs:None ~acodecs:None in
  Stdlib.Printf.printf "v=%s a=%s\n"
    (String.concat ~sep:"," (List.map v ~f:Codec.Video.to_string))
    (String.concat ~sep:"," (List.map a ~f:Codec.Audio.to_string));
  [%expect {| v=av1,hevc,vp9,avc a=opus,aac,flac |}]

let%expect_test "effective_codecs: device when no override" =
  let entry : Device.t = {
    id = "x"; friendly_name = "tv"; vendor = Vendor.Generic;
    stream_format = Api.Stream_format.Hls;
    transcode = false;
    max_width = 3840; max_height = 2160;
    last_seen = 0.;
    video_codecs = [ Codec.Video.Avc ];
    audio_codecs = [ Codec.Audio.Aac ];
    client = Airplay {
      name = "n"; fn = Some "tv"; address = "1"; port = 7000;
      pairing_id = "p"; public_key = None;
      features = None; flags = None; model = None; txt = [];
    }
  } in
  let v, a = effective_codecs ~entry:(Some entry) ~vcodecs:None ~acodecs:None in
  Stdlib.Printf.printf "v=%s a=%s\n"
    (String.concat ~sep:"," (List.map v ~f:Codec.Video.to_string))
    (String.concat ~sep:"," (List.map a ~f:Codec.Audio.to_string));
  [%expect {| v=avc a=aac |}]

let%expect_test "effective_codecs: request overrides device" =
  let entry : Device.t = {
    id = "x"; friendly_name = "tv"; vendor = Vendor.Generic;
    stream_format = Api.Stream_format.Hls;
    transcode = false;
    max_width = 3840; max_height = 2160;
    last_seen = 0.;
    video_codecs = [ Codec.Video.Avc ];
    audio_codecs = [ Codec.Audio.Aac ];
    client = Airplay {
      name = "n"; fn = Some "tv"; address = "1"; port = 7000;
      pairing_id = "p"; public_key = None;
      features = None; flags = None; model = None; txt = [];
    }
  } in
  let v, a =
    effective_codecs ~entry:(Some entry)
      ~vcodecs:(Some ["hevc"]) ~acodecs:None
  in
  Stdlib.Printf.printf "v=%s a=%s\n"
    (String.concat ~sep:"," (List.map v ~f:Codec.Video.to_string))
    (String.concat ~sep:"," (List.map a ~f:Codec.Audio.to_string));
  [%expect {| v=hevc a=aac |}]

let%expect_test "effective_codecs: rejects unknown codec" =
  (match effective_codecs ~entry:None
           ~vcodecs:(Some ["bogus"]) ~acodecs:None with
   | _ -> Stdlib.print_endline "ok?"
   | exception Json_io.Http_error (_, e) -> Stdlib.print_endline e);
  [%expect {| unknown video codec: bogus |}]
