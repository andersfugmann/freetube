module Err = Error
open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay 2 Connection 2 URL-playback session" Stdlib.__MODULE__)

let ( let* ) x f = Result.bind x ~f

(* Convert a network/parse exception at the I/O boundary into the error
   monad so nothing below raises out of this module. *)
let in_monad f =
  Result.try_with f
  |> Result.map_error ~f:(fun exn -> Err.Network (Exn.to_string exn))

type identifiers = {
  session_uuid : string;
  rtsp_session_id : string;
  dacp_id : string;
  active_remote : string;
}

type t = {
  control_stream : Hap_stream.state;
  control_buf : Hap_stream.plaintext_buffer;
  ids : identifiers;
  uri : string;
  stream_id : int;
  cseq : int ref;
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  mutable feedback_started : bool;
  cancel_promise : unit Eio.Promise.t;
  cancel_resolver : unit Eio.Promise.u;
}

let user_agent_command = "AirPlay/870.14.1"
let user_agent_rtsp = "AirPlay/550.10"

let random_hex_uppercase ~bytes =
  let raw = Mirage_crypto_rng.generate bytes in
  let hex = Ohex.encode raw in
  String.uppercase hex

let random_decimal ~bytes =
  let raw = Mirage_crypto_rng.generate bytes in
  let value =
    String.fold raw ~init:0 ~f:(fun acc c -> (acc lsl 8) lor Char.to_int c)
    land 0x7fffffff
  in
  Int.to_string value

let random_uuid = Uuid.v4_uppercase

let new_identifiers () =
  {
    session_uuid = random_uuid ();
    rtsp_session_id = random_decimal ~bytes:4;
    dacp_id = random_hex_uppercase ~bytes:8;
    active_remote = random_decimal ~bytes:4;
  }

let session_uri ~local_ip ~rtsp_session_id =
  Printf.sprintf "rtsp://%s/%s" local_ip rtsp_session_id

let rtsp_headers ~ids ~content_type ~body_length =
  let base =
    [
      "User-Agent", user_agent_rtsp;
      "DACP-ID", ids.dacp_id;
      "Active-Remote", ids.active_remote;
      "Client-Instance", ids.dacp_id;
      "X-Apple-Session-ID", ids.session_uuid;
    ]
  in
  let with_body =
    match body_length > 0 with
    | false -> base
    | true ->
        base
        @ [ "Content-Type", content_type ]
  in
  with_body

let cseq_header n = "CSeq", Int.to_string n

let bump cseq =
  let value = !cseq in
  cseq := value + 1;
  value

let make_rtsp_request ~method_ ~uri ~ids ~cseq ~body =
  let headers =
    cseq_header cseq
    :: rtsp_headers ~ids ~content_type:"application/x-apple-binary-plist"
         ~body_length:(String.length body)
  in
  let request_line = Printf.sprintf "%s %s RTSP/1.0" method_ uri in
  request_line, headers

let send_rtsp_with_body stream buf ~method_ ~uri ~ids ~cseq ~path ~body =
  let target =
    match String.is_empty path with
    | true -> uri
    | false -> path
  in
  let request_line, headers = make_rtsp_request ~method_ ~uri:target ~ids ~cseq ~body in
  in_monad (fun () -> Airplay_http.send_and_read stream buf ~request_line ~headers ~body)

let post_rtsp stream buf ~uri ~ids ~cseq ~path ~body =
  send_rtsp_with_body stream buf ~method_:"POST" ~uri ~ids ~cseq ~path ~body

let send_rtsp_simple stream buf ~method_ ~uri ~ids ~cseq =
  let request_line, headers = make_rtsp_request ~method_ ~uri ~ids ~cseq ~body:"" in
  in_monad (fun () -> Airplay_http.send_and_read stream buf ~request_line ~headers ~body:"")

let check_status response context =
  match response.Airplay_http.status with
  | 200 -> Ok ()
  | code ->
    Log.warn (fun m -> m "%s: status: %d. body: '%s'" context code response.Airplay_http.body);
    List.iter response.headers ~f:(fun (k, v) ->
        Log.warn (fun m -> m "%s: header: %s=%s" context k v)
      );
    Error (Err.Command_rejected { action = context; status = code })

let setup_body_connection2 ~ids ~timing_port =
  Bplist.encode
    (Bplist.dict
       [
         "deviceID", Bplist.str Identity.device_id;
         "sessionUUID", Bplist.str ids.session_uuid;
         "timingPort", Bplist.int_ timing_port;
         "timingProtocol", Bplist.str "NTP";
         "isMultiSelectAirPlay", Bplist.bool_ true;
         "groupContainsGroupLeader", Bplist.bool_ false;
         "macAddress", Bplist.str Identity.mac_address;
         "model", Bplist.str Identity.model;
         "name", Bplist.str Identity.name;
         "osBuildVersion", Bplist.str Identity.os_build;
         "osName", Bplist.str Identity.os_name;
         "osVersion", Bplist.str Identity.os_version;
         "senderSupportsRelay", Bplist.bool_ false;
         "sourceVersion", Bplist.str Identity.source_version;
         "statsCollectionEnabled", Bplist.bool_ false;
       ])

let url_stream_setup_body ~channel_id =
  let client_uuid = random_uuid () in
  Bplist.encode
    (Bplist.dict
       [
         "streams",
         Bplist.arr
           [
             Bplist.dict
               [
                 "channelID", Bplist.str channel_id;
                 "clientTypeUUID", Bplist.str Identity.url_stream_client_type_uuid;
                 "clientUUID", Bplist.str client_uuid;
                 "controlType", Bplist.int_ 1;
                 "type", Bplist.int_ 130;
               ];
           ];
       ])

let command_envelope ~inner =
  Bplist.encode
    (Bplist.dict [ "params", Bplist.dict [ "data", Bplist.data inner ] ])

let insert_play_queue_inner ~item_uuid ~content_url =
  Bplist.encode
    (Bplist.dict
       [
         "type", Bplist.str "insertPlayQueueItem";
         "item",
         Bplist.dict
           [
             "uuid", Bplist.str item_uuid;
             "mediaType", Bplist.str "file";
             "Content-Location", Bplist.str content_url;
           ];
       ])

let set_property_with_item_inner ~property ~item_uuid ~value =
  Bplist.encode
    (Bplist.dict
       [
         "type", Bplist.str "setProperty";
         "property", Bplist.str property;
         "value", value;
         "item", Bplist.dict [ "uuid", Bplist.str item_uuid ];
       ])

let set_property_inner ~property ~value =
  Bplist.encode
    (Bplist.dict
       [
         "type", Bplist.str "setProperty";
         "property", Bplist.str property;
         "value", value;
       ])

let set_rate_inner ~rate =
  Bplist.encode
    (Bplist.dict
       [
         "type", Bplist.str "setRate";
         "rate", Bplist.real_ rate;
       ])

let post_command stream buf ~ids ~cseq ~stream_id ~inner =
  let body = command_envelope ~inner in
  let headers =
    [
      "User-Agent", user_agent_command;
      "X-Apple-ProtocolVersion", "1";
      "X-Apple-Session-ID", ids.session_uuid;
      "X-Apple-StreamID", Int.to_string stream_id;
      "DACP-ID", ids.dacp_id;
      "Active-Remote", ids.active_remote;
      "Client-Instance", ids.dacp_id;
      "Content-Type", "application/x-apple-binary-plist";
      cseq_header cseq;
    ]
  in
  in_monad (fun () ->
    Airplay_http.send_and_read stream buf ~request_line:"POST /command HTTP/1.1" ~headers ~body)

let parse_event_port response =
  let* plist = in_monad (fun () -> Bplist.decode response.Airplay_http.body) in
  match Bplist.find_int "eventPort" plist with
  | Some port -> Ok port
  | None -> Error (Err.Bad_response "SETUP response missing eventPort")

let parse_stream_id response =
  let* plist = in_monad (fun () -> Bplist.decode response.Airplay_http.body) in
  let* streams =
    match Bplist.find_array "streams" plist with
    | Some streams -> Ok streams
    | None -> Error (Err.Bad_response "stream SETUP response missing streams")
  in
  match streams with
  | first :: _ ->
      (match Bplist.find_int "streamID" first with
       | Some id -> Ok id
       | None -> Error (Err.Bad_response "stream SETUP response missing streamID"))
  | [] -> Error (Err.Bad_response "stream SETUP response had empty streams array")

let derive_event_keys ~shared_secret =
  let encrypt_key =
    Hkdf.derive
      ~salt:"Events-Salt"
      ~info:"Events-Read-Encryption-Key"
      ~length:32
      ~ikm:shared_secret
  in
  let decrypt_key =
    Hkdf.derive
      ~salt:"Events-Salt"
      ~info:"Events-Write-Encryption-Key"
      ~length:32
      ~ikm:shared_secret
  in
  Pair_verify.{ encrypt_key; decrypt_key; shared_secret }

let acknowledge_event_request stream cseq =
  Hap_stream.write stream
    (Printf.sprintf "RTSP/1.0 200 OK\r\nCSeq: %s\r\nContent-Length: 0\r\n\r\n" cseq)

let format_event_assoc assoc =
  let rec value_to_string = function
    | Bplist.Null -> "null"
    | Bool b -> Bool.to_string b
    | Int i -> Int.to_string i
    | Real f -> Float.to_string f
    | String s -> Printf.sprintf "%S" s
    | Data d ->
        (match Bplist.decode_assoc d with
         | Some items -> "<" ^ assoc_to_string items ^ ">"
         | None -> Printf.sprintf "<data:%d>" (String.length d))
    | Array xs ->
        "[" ^ String.concat ~sep:"; " (List.map xs ~f:value_to_string) ^ "]"
    | Dict items -> "{" ^ assoc_to_string items ^ "}"
  and assoc_to_string items =
    String.concat ~sep:"; "
      (List.map items ~f:(fun (k, v) -> k ^ "=" ^ value_to_string v))
  in
  assoc_to_string assoc

let is_playback_stopped assoc =
  let open Bplist in
  match List.Assoc.find assoc ~equal:String.equal "params" with
  | Some (Dict params) ->
      let data =
        match List.Assoc.find params ~equal:String.equal "data" with
        | Some (Data raw) -> Bplist.decode_assoc raw
        | Some (Dict d) -> Some d
        | _ -> None
      in
      (match data with
       | Some items ->
           (match List.Assoc.find items ~equal:String.equal "type",
                  List.Assoc.find items ~equal:String.equal "name" with
            | Some (String "playbackState"), Some (String "stopped") -> true
            | _ -> false)
       | None -> false)
  | _ -> false

let start_event_receiver ~sw ~cancel_resolver ~event_stream =
  let rec loop event_buf =
    let (request_line, headers, body) = Airplay_http.read_request event_buf in
    let assoc =
      Option.value (Bplist.decode_assoc body) ~default:[]
    in
    Log.debug (fun m -> m "event channel <- %s { %s }"
                 request_line (format_event_assoc assoc));
    let cseq =
      List.find_map headers ~f:(fun (k, v) ->
          match String.equal (String.lowercase k) "cseq" with
          | true -> Some v
          | false -> None)
      |> Option.value ~default:"0"
    in
    acknowledge_event_request event_stream cseq;
    match is_playback_stopped assoc with
    | true ->
        Log.info (fun m -> m "playback stopped by remote");
        ignore (Eio.Promise.try_resolve cancel_resolver () : bool)
    | false -> loop event_buf
  in

  let event_buf = Hap_stream.to_plaintext_buffer event_stream in
  Eio.Fiber.fork ~sw (fun () ->
      Log.debug (fun m -> m "event channel reader started");
      match loop event_buf with
      | () ->
        Log.debug (fun m -> m "event channel reader done");
        ignore (Eio.Promise.try_resolve cancel_resolver () : bool)
      | exception Eio.Cancel.Cancelled _ ->
        Log.debug (fun m -> m "event channel reader cancelled")
      | exception exn ->
        Log.info (fun m -> m "event channel reader exiting: %s"
                    (Exn.to_string exn));
        ignore (Eio.Promise.try_resolve cancel_resolver () : bool))

let connect_event_channel ~net ~sw ~address ~port ~shared_secret =
  let flow = Http_tcp.connect ~net ~sw ~address ~port in
  let event_keys = derive_event_keys ~shared_secret in
  Hap_stream.create ~session_keys:event_keys ~flow:flow.flow

let create ~env ~sw ~address ~port ~credentials ~ntp_port =
  Log.info (fun m -> m "AirPlay session starting against %s:%d" address port);
  let net = Eio.Stdenv.net env in
  let local_ip = Local_ip.for_address ~net ~address ~port in
  let conn2_ids = new_identifiers () in
  let conn2_uri = session_uri ~local_ip ~rtsp_session_id:conn2_ids.rtsp_session_id in
  let cseq = ref 0 in

  Log.info (fun m -> m "Connection 2: pair-verify");
  let* conn2_stream, conn2_keys =
    Result.try_with (fun () ->
      Pair_verify_driver.run ~net ~sw ~address ~port ~credentials)
    |> Result.map_error ~f:(fun exn -> Err.Auth_failed (Exn.to_string exn))
  in
  let conn2_buf = Hap_stream.to_plaintext_buffer conn2_stream in
  let conn2_secret = conn2_keys.Pair_verify.shared_secret in

  Log.info (fun m -> m "Connection 2: RTSP SETUP NTP");
  let* response =
    send_rtsp_with_body conn2_stream conn2_buf ~method_:"SETUP"
      ~uri:conn2_uri ~ids:conn2_ids ~cseq:(bump cseq) ~path:""
      ~body:(setup_body_connection2 ~ids:conn2_ids ~timing_port:ntp_port)
  in
  let* () = check_status response "Connection 2 SETUP" in
  let* conn2_event_port = parse_event_port response in
  Log.info (fun m -> m "Connection 2 event port=%d" conn2_event_port);
  let* conn2_event_stream =
    in_monad (fun () ->
      connect_event_channel ~net ~sw ~address ~port:conn2_event_port
        ~shared_secret:conn2_secret)
  in
  let cancel_promise, cancel_resolver = Eio.Promise.create () in
  start_event_receiver ~sw ~cancel_resolver ~event_stream:conn2_event_stream;

  Log.info (fun m -> m "Connection 2: RTSP RECORD");
  let* response =
    send_rtsp_simple conn2_stream conn2_buf ~method_:"RECORD"
      ~uri:conn2_uri ~ids:conn2_ids ~cseq:(bump cseq)
  in
  let* () = check_status response "Connection 2 RECORD" in

  Log.info (fun m -> m "Connection 2: RTSP SETUP streams (URL playback)");
  let* response =
    send_rtsp_with_body conn2_stream conn2_buf ~method_:"SETUP"
      ~uri:conn2_uri ~ids:conn2_ids ~cseq:(bump cseq) ~path:""
      ~body:(url_stream_setup_body ~channel_id:Identity.url_stream_channel_id)
  in
  let* () = check_status response "Connection 2 SETUP streams" in
  let* stream_id = parse_stream_id response in
  Log.info (fun m -> m "stream_id=%d" stream_id);

  Ok {
    control_stream = conn2_stream;
    control_buf = conn2_buf;
    ids = conn2_ids;
    uri = conn2_uri;
    stream_id;
    cseq;
    env;
    sw;
    feedback_started = false;
    cancel_promise;
    cancel_resolver;
  }

let start_feedback_fiber t =
  let rec loop clock =
    match Eio.Promise.is_resolved t.cancel_promise with
    | true -> ()
    | false ->
      match
        post_rtsp t.control_stream t.control_buf ~uri:t.uri
          ~ids:t.ids ~cseq:(bump t.cseq) ~path:"/feedback" ~body:""
      with
      | Error err ->
          Log.info (fun m -> m "feedback error: %s" (Err.to_string err));
          ignore (Eio.Promise.try_resolve t.cancel_resolver () : bool)
      | Ok (_ : Airplay_http.response) ->
          Eio.Fiber.first
            (fun () -> Eio.Promise.await t.cancel_promise)
            (fun () -> Eio.Time.sleep clock 2.0);
          loop clock
  in
  Eio.Fiber.fork ~sw:t.sw (fun () ->
      let clock = Eio.Stdenv.clock t.env in
      try
        loop clock
      with
      | Eio.Cancel.Cancelled _ -> ()
      | exn ->
        Log.info (fun m -> m "feedback error: %s" (Exn.to_string exn));
        ignore (Eio.Promise.try_resolve t.cancel_resolver () : bool)
    )

let play t ~content_url =
  let item_uuid = random_uuid () in
  Log.info (fun m -> m "POST /command insertPlayQueueItem");
  let* response =
    post_command t.control_stream t.control_buf ~ids:t.ids ~cseq:(bump t.cseq)
      ~stream_id:t.stream_id
      ~inner:(insert_play_queue_inner ~item_uuid ~content_url)
  in
  let* () = check_status response "insertPlayQueueItem" in

  Log.info (fun m -> m "POST /command setProperty isInterestedInDateRange");
  let* _ =
    post_command t.control_stream t.control_buf ~ids:t.ids ~cseq:(bump t.cseq)
      ~stream_id:t.stream_id
      ~inner:
        (set_property_with_item_inner ~property:"isInterestedInDateRange"
           ~item_uuid ~value:(Bplist.bool_ true))
  in

  Log.info (fun m -> m "POST /command setProperty actionAtItemEnd");
  let* _ =
    post_command t.control_stream t.control_buf ~ids:t.ids ~cseq:(bump t.cseq)
      ~stream_id:t.stream_id
      ~inner:
        (set_property_inner ~property:"actionAtItemEnd"
           ~value:(Bplist.int_ 1))
  in
  Log.info (fun m -> m "POST /command setRate 1.0");
  let* response =
    post_command t.control_stream t.control_buf ~ids:t.ids ~cseq:(bump t.cseq)
      ~stream_id:t.stream_id
      ~inner:(set_rate_inner ~rate:1.0)
  in
  let* () = check_status response "setRate" in

  Log.info (fun m -> m "RTSP POST /rate");
  let* _ =
    post_rtsp t.control_stream t.control_buf ~uri:t.uri ~ids:t.ids
      ~cseq:(bump t.cseq) ~path:"/rate?value=1.000000" ~body:""
  in

  (match t.feedback_started with
   | true -> ()
   | false ->
       t.feedback_started <- true;
       start_feedback_fiber t);
  Log.info (fun m -> m "AirPlay playback started");
  Ok ()

let stop t =
  Log.info (fun m -> m "Stopping AirPlay session");
  (match Eio.Promise.is_resolved t.cancel_promise with
   | true -> ()
   | false ->
     (match
        send_rtsp_simple t.control_stream t.control_buf ~method_:"TEARDOWN"
          ~uri:t.uri ~ids:t.ids ~cseq:(bump t.cseq)
      with
      | Ok (_ : Airplay_http.response) -> ()
      | Error message -> Log.info (fun m -> m "TEARDOWN: %s" (Err.to_string message))));
  ignore (Eio.Promise.try_resolve t.cancel_resolver () : bool)

let set_rate t rate =
  let* _ =
    post_command t.control_stream t.control_buf ~ids:t.ids
      ~cseq:(bump t.cseq) ~stream_id:t.stream_id
      ~inner:(set_rate_inner ~rate)
  in
  Ok ()

let pause t =
  Log.info (fun m -> m "AirPlay pause (setRate 0.0)");
  set_rate t 0.0

let resume t =
  Log.info (fun m -> m "AirPlay resume (setRate 1.0)");
  set_rate t 1.0

let seek t ~seconds =
  Log.info (fun m -> m "AirPlay seek to %.3fs" seconds);
  let path = Printf.sprintf "/scrub?position=%f" seconds in
  let* _ =
    post_rtsp t.control_stream t.control_buf ~uri:t.uri ~ids:t.ids
      ~cseq:(bump t.cseq) ~path ~body:""
  in
  Ok ()

let terminated t = t.cancel_promise

let connect ~env ~sw ~client ~credentials ~ntp =
  create ~env ~sw ~address:(Airplay.Client.address client) ~port:(Airplay.Client.port client)
    ~credentials
    ~ntp_port:(Ntp_server.port ntp)
