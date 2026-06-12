open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HTTP server" Stdlib.__MODULE__)

let not_found () =
  Piaf.Response.of_string ~body:"Not Found" `Not_found

let method_not_allowed () =
  Piaf.Response.of_string ~body:"Method Not Allowed" `Method_not_allowed

let mimetype_of_filename filename =
  match String.suffix filename 4 with
  | ".mpd" -> "application/dash+xml"
  | _ -> Magic_mime.lookup filename

let request_method = function
  | `GET -> `GET
  | `POST -> `POST
  | `PUT -> `PUT
  | `DELETE -> `DELETE
  | `HEAD -> `HEAD
  | `OPTIONS -> `OPTIONS
  | meth -> `Other (Piaf.Method.to_string meth)

let parse_range = function
  | None -> Request.No_range
  | Some header ->
      let h = String.lowercase (String.strip header) in
      match String.chop_prefix h ~prefix:"bytes=" with
      | None -> Invalid_range
      | Some spec ->
          let first = String.split spec ~on:',' |> List.hd_exn |> String.strip in
          (match String.split first ~on:'-' with
           | [ start_s; end_s ] ->
               let start = Stdlib.int_of_string_opt (String.strip start_s) in
               let finish = Stdlib.int_of_string_opt (String.strip end_s) in
               (match start, finish with
                | None, Some suffix when suffix > 0 -> Byte_range (Suffix suffix)
                | Some s, None when s >= 0 -> Byte_range (From s)
                | Some s, Some e when s >= 0 && s <= e -> Byte_range (From_to (s, e))
                | _ -> Invalid_range)
           | _ -> Invalid_range)

let request_of_piaf ~client (request : Piaf.Request.t) =
  let headers =
    Piaf.Headers.to_list request.headers
    |> List.map ~f:(fun (k, v) -> String.lowercase k, v)
  in
  let host =
    match List.Assoc.find headers ~equal:String.equal "host" with
    | Some h -> Request.Host h
    | None -> No_host
  in
  let range =
    List.Assoc.find headers ~equal:String.equal "range"
    |> parse_range
  in
  let body =
    match Piaf.Body.to_string (Piaf.Request.body request) with
    | Ok b -> b
    | Error _ -> ""
  in
  {
    Request.method_ = request_method (Piaf.Request.meth request);
    path = Uri.path (Piaf.Request.uri request);
    headers;
    body;
    range;
    host;
    client = Request.Peer client;
  }

let range_slice ~total = function
  | Request.Suffix suffix ->
      let length = Int.min suffix total in
      if length = 0 then Error (`Range_not_satisfiable total)
      else Ok (total - length, length)
  | Request.From start ->
      if start < total then Ok (start, total - start)
      else Error (`Range_not_satisfiable total)
  | Request.From_to (start, finish) ->
      if start < total then
        let last = Int.min finish (total - 1) in
        Ok (start, last - start + 1)
      else Error (`Range_not_satisfiable total)

let status_of = function
  | Response.Ok -> `OK
  | No_content -> `No_content

let content_type_of = function
  | Response.No_content_type -> None
  | Explicit ct -> Some ct
  | Infer_from_filename filename -> Some (mimetype_of_filename filename)

let to_piaf_response ~is_head req (response : Response.t) =
  let total = String.length response.body in
  let with_range =
    match response.accept_ranges, req.Request.range with
    | No_ranges, _ -> Ok (`Whole response.body, status_of response.status, None)
    | Allow_ranges, No_range -> Ok (`Whole response.body, status_of response.status, None)
    | Allow_ranges, Invalid_range when total > 0 -> Error (`Range_not_satisfiable total)
    | Allow_ranges, Invalid_range -> Ok (`Whole response.body, status_of response.status, None)
    | Allow_ranges, Byte_range spec ->
        range_slice ~total spec
        |> Result.map ~f:(fun (offset, length) ->
          let data = String.sub response.body ~pos:offset ~len:length in
          let content_range =
            Printf.sprintf "bytes %d-%d/%d" offset (offset + length - 1) total
          in
          `Whole data, `Partial_content, Some content_range)
  in
  match with_range with
  | Error (`Range_not_satisfiable total) ->
      let headers =
        Piaf.Headers.of_list
          [ "content-range", Printf.sprintf "bytes */%d" total ]
      in
      Piaf.Response.of_string ~headers ~body:"" `Range_not_satisfiable
  | Ok (`Whole body, status, content_range) ->
      let base_headers =
        let headers = response.headers in
        let headers =
          match content_type_of response.content_type with
          | Some ct -> ("content-type", ct) :: headers
          | None -> headers
        in
        let headers =
          match response.accept_ranges with
          | Allow_ranges -> ("accept-ranges", "bytes") :: headers
          | No_ranges -> headers
        in
        let headers =
          match content_range with
          | Some value -> ("content-range", value) :: headers
          | None -> headers
        in
        ("content-length", Int.to_string (String.length body)) :: headers
      in
      let headers = Piaf.Headers.of_list base_headers in
      match is_head with
      | true -> Piaf.Response.create ~headers status
      | false -> Piaf.Response.of_string ~headers ~body status

let response_of_error = function
  | `Not_found ->
      Piaf.Response.of_string ~body:"not found" `Not_found
  | `Bad_param msg ->
      Piaf.Response.of_string ~body:msg `Bad_request
  | `Conflict msg ->
      Piaf.Response.of_string ~body:msg `Conflict
  | `Unauthorized msg ->
      Piaf.Response.of_string ~body:msg `Unauthorized
  | `Upstream_error msg ->
      Piaf.Response.of_string ~body:msg `Bad_gateway
  | `Internal_error msg ->
      Piaf.Response.of_string ~body:msg `Internal_server_error
  | `Range_not_satisfiable total ->
      let headers =
        Piaf.Headers.of_list
          [ "content-range", Printf.sprintf "bytes */%d" total ]
      in
      Piaf.Response.of_string ~headers ~body:"" `Range_not_satisfiable

let routers ~app ~client =
  let open Routes in
  let post = one_of [
    s "pause" /? nil @--> Sessions_handler.handle_pause ~app;
    s "resume" /? nil @--> Sessions_handler.handle_resume ~app;
    s "seek" /? nil @--> Sessions_handler.handle_seek ~app;
    s "close" /? nil @--> Sessions_handler.handle_close ~app;
    s "airplay" / s "pair" /? nil @--> Airplay_handler.handle_pair ~app;
    s "sessions" /? nil @--> Sessions_handler.handle_create ~app;
    s "sessions" / str / s "pause" /? nil @--> (fun id _ ->
      Sessions_handler.handle_post_pause ~app ~id);
    s "sessions" / str / s "resume" /? nil @--> (fun id _ ->
      Sessions_handler.handle_post_resume ~app ~id);
    s "sessions" / str / s "seek" /? nil @--> (fun id request ->
      Sessions_handler.handle_post_seek ~app ~id request);
  ]
  in
  let get = one_of [
    (s "p" /? nil) @--> (fun (_ : Request.t) -> Sessions_handler.handle_player_page ~app);
    (s "config" /? nil) @--> Config_handler.handle_get;
    (s "sessions" /? nil) @--> (fun (_ : Request.t) -> Sessions_handler.handle_list ~app);
    (s "devices" /? nil) @--> (fun (_ : Request.t) -> Devices_handler.handle_list ~app);
    (s "devices" / str / s "config" /? nil) @--> (fun id _ ->
      Devices_handler.handle_get_config ~app ~id);
    (s "sessions" / str /? wildcard) @--> (fun id sub_path request ->
      Sessions_handler.handle_session_request ~app ~id ~sub_path request);
    (s "session" / str /? wildcard) @--> (fun id sub_path request ->
      Sessions_handler.handle_session_request ~app ~id ~sub_path request);
  ]
  in
  let put = one_of [
    s "config" /? nil @--> Config_handler.handle_put ~app;
    s "devices" / str / s "config" /? nil @--> (fun id request ->
      Devices_handler.handle_put_config ~app ~id request);
  ]
  in
  let delete = one_of [
    s "sessions" / str /? nil @--> (fun id _ ->
      Sessions_handler.handle_delete_session ~app ~id);
    s "devices" / str / s "config" /? nil @--> (fun id _ ->
      Devices_handler.handle_delete_config ~app ~id);
  ]
  in
  let request = request_of_piaf ~client in
  `POST post, `GET get, `PUT put, `DELETE delete, request

let route ~router ~target ~request =
  match Routes.match' router ~target with
  | FullMatch handler -> Some (handler request)
  | MatchWithTrailingSlash handler -> Some (handler request)
  | NoMatch -> None

let start_server ~address ~sw ~env ~handler ~error_handler =
  let config = Piaf.Server.Config.create ~reuse_addr:true address in
  let server = Piaf.Server.create ~config ~error_handler handler in
  Piaf.Server.Command.start ~sw env server

let start ~env ~port ~device_store ~ntp ~sw =
  let sessions = Sessions.init () in
  let clock = Eio.Stdenv.clock env in
  let global = Config.get () in
  let app : _ App.t = {
    env; sw; port;
    device_store;
    global;
    sessions;
    ntp;
  }
  in
  let dispatch ~client (request : Piaf.Request.t) =
    let target = Uri.path (Piaf.Request.uri request) in
    let `POST post, `GET get, `PUT put, `DELETE delete, request_of =
      routers ~app ~client
    in
    let is_head = match Piaf.Request.meth request with `HEAD -> true | _ -> false in
    let selected =
      match Piaf.Request.meth request with
      | `POST -> Some post
      | `GET | `HEAD -> Some get
      | `PUT -> Some put
      | `DELETE -> Some delete
      | _ -> None
    in
    match selected with
    | None -> method_not_allowed ()
    | Some router ->
        let internal_request = request_of request in
        (match route ~router ~target ~request:internal_request with
         | Some (Ok response) -> to_piaf_response ~is_head internal_request response
         | Some (Error error) -> response_of_error error
         | None ->
             let exists_elsewhere =
               List.exists [ post; get; put; delete ] ~f:(fun candidate ->
                 match Routes.match' candidate ~target with
                 | NoMatch -> false
                 | _ -> true)
             in
             match exists_elsewhere with
             | true -> method_not_allowed ()
             | false -> not_found ())
  in
  let handler ({ Piaf.Server.ctx; request } : _ Piaf.Server.ctx) =
    let client = ctx.Piaf.Request_info.client_address in
    Middleware.log_request ~clock
      ~dispatch:(Cors.wrap ~dispatch:(dispatch ~client))
      request
  in
  let is_connection_closed = function
    | `Exn End_of_file -> true
    | `Exn (Eio.Exn.Io (Eio.Net.E (Connection_reset _), _)) -> true
    | _ -> false
  in
  let error_handler _client_addr ?request ~respond error =
    let path =
      match request with
      | Some r -> Uri.path (Piaf.Request.uri r)
      | None -> "<unknown>"
    in
    match is_connection_closed error with
    | true ->
        Log.info (fun m -> m "client disconnected: path=%s" path);
        respond ~headers:Piaf.Headers.empty (Piaf.Body.empty)
    | false ->
        let error_str =
          match error with
          | `Exn exn -> Exn.to_string exn
          | `Protocol_error (_, msg) -> Printf.sprintf "protocol: %s" msg
          | `TLS_error _ -> "TLS error"
          | `Upgrade_not_supported -> "upgrade not supported"
          | `Msg msg -> msg
          | `Bad_gateway -> "bad gateway"
          | `Bad_request -> "bad request"
          | `Internal_server_error -> "internal server error"
        in
        Log.warn (fun m ->
          m "server error: path=%s error=%s" path error_str);
        respond ~headers:Piaf.Headers.empty (Piaf.Body.empty)
  in
  let (_command : Piaf.Server.Command.t) =
    start_server ~sw ~env ~address:(`Tcp (Eio.Net.Ipaddr.V4.any, port))
      ~handler ~error_handler
  in
  let (_command : Piaf.Server.Command.t) =
    start_server ~sw ~env ~address:(`Tcp (Eio.Net.Ipaddr.V6.any, port))
      ~handler ~error_handler
  in
  Log.info (fun m -> m "Freetube started on port %d" port);
  Eio.Fiber.await_cancel ()

