open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HTTP server" Stdlib.__MODULE__)

let not_found () =
  Piaf.Response.of_string ~body:"Not Found" `Not_found

let method_not_allowed () =
  Piaf.Response.of_string ~body:"Method Not Allowed" `Method_not_allowed

let routers ~app ~static_root ~sw ~client_address =
  let open Routes in
  let post = one_of [
    (* Legacy session-control endpoints (back-compat). *)
    s "pause"     /? nil @--> Sessions_handler.handle_pause  ~app;
    s "resume"    /? nil @--> Sessions_handler.handle_resume ~app;
    s "seek"      /? nil @--> Sessions_handler.handle_seek   ~app;
    s "close"     /? nil @--> Sessions_handler.handle_close  ~app;
    s "airplay" / s "pair" /? nil @--> Airplay_handler.handle_pair ~app;
    s "sessions" /? nil @--> Sessions_handler.handle_create ~app ~client_address;
    s "sessions" / str / s "pause" /? nil @--> (fun id _ ->
      Sessions_handler.handle_post_pause ~app ~id);
    s "sessions" / str / s "resume" /? nil @--> (fun id _ ->
      Sessions_handler.handle_post_resume ~app ~id);
    s "sessions" / str / s "seek" /? nil @--> (fun id request ->
      Sessions_handler.handle_post_seek ~app ~id request);
  ]
  in
  let get = one_of [
    (s "p" /? nil) @--> (fun (_ : Piaf.Request.t) -> Sessions_handler.handle_player_page ~app);
    (s "config" /? nil) @--> Config_handler.handle_get;
    (s "sessions" /? nil) @--> (fun (_ : Piaf.Request.t) -> Sessions_handler.handle_list ~app);
    (s "devices"  /? nil) @--> (fun (_ : Piaf.Request.t) -> Devices_handler.handle_list ~app);
    (s "devices" / str / s "config" /? nil) @--> (fun id _ ->
      Devices_handler.handle_get_config ~app ~id);
    (s "sessions" / str /? wildcard) @--> (fun id sub_path request ->
      Sessions_handler.handle_session_request ~app ~id ~sub_path request);
    (* Legacy path: /session/<id>/... *)
    (s "session" / str /? wildcard) @--> (fun id sub_path request ->
      Sessions_handler.handle_session_request ~app ~id ~sub_path request);
    (s "static" /? wildcard) @--> (fun _ request ->
      Static.serve ~sw ~root:static_root request);
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
  let strip_body response =
    let body = Piaf.Response.body response in
    let length_header =
      match Piaf.Body.length body with
      | `Fixed n -> [ "content-length", Int64.to_string n ]
      | `Chunked | `Close_delimited | `Error _ | `Unknown -> []
    in
    let headers =
      List.fold length_header ~init:(Piaf.Response.headers response)
        ~f:(fun acc (k, v) -> Piaf.Headers.add_unless_exists acc k v)
    in
    Piaf.Response.with_ response ~body:Piaf.Body.empty ~headers
  in
  let as_head (route : (Piaf.Request.t -> Piaf.Response.t) Routes.route) =
    Routes.map (fun handler request -> strip_body (handler request)) route
  in
  let head =
    one_of (List.map ~f:as_head [
      (s "static" /? wildcard) @--> (fun _ request ->
        Static.serve ~sw ~root:static_root request);
      (s "sessions" /? nil) @--> (fun _ -> Sessions_handler.handle_list ~app);
      (s "devices"  /? nil) @--> (fun _ -> Devices_handler.handle_list ~app);
      (s "devices" / str / s "config" /? nil) @--> (fun id _ ->
        Devices_handler.handle_get_config ~app ~id);
      (s "sessions" / str /? wildcard) @--> (fun id sub_path request ->
        Sessions_handler.handle_session_request ~app ~id ~sub_path request);
      (s "session" / str /? wildcard) @--> (fun id sub_path request ->
        Sessions_handler.handle_session_request ~app ~id ~sub_path request);
    ])
  in
  `POST post, `GET get, `PUT put, `DELETE delete, `HEAD head

let route ~router ~target ~request =
  match Routes.match' router ~target with
  | FullMatch handler -> Some (handler request)
  | MatchWithTrailingSlash handler -> Some (handler request)
  | NoMatch -> None

let start_server ~address ~sw ~env ~handler ~error_handler =
  let config = Piaf.Server.Config.create ~reuse_addr:true address in
  let server = Piaf.Server.create ~config ~error_handler handler in
  let command = Piaf.Server.Command.start ~sw env server in
  command

let start ~env ~port ~static_root ~device_store ~ntp ~sw =
  let sessions = Sessions.init () in
  let clock = Eio.Stdenv.clock env in
  let global = Config.get () in
  let app : _ App.t = {
    env; sw; port; static_root;
    device_store;
    global;
    sessions;
    ntp;
  }
  in
  let dispatch ~client_address (request : Piaf.Request.t) =
    let target = Uri.path (Piaf.Request.uri request) in
    let `POST post, `GET get, `PUT put, `DELETE delete, `HEAD head =
      routers ~app ~static_root ~sw ~client_address
    in
    let all_routers = [ post; get; put; delete; head ] in
    let selected =
      match Piaf.Request.meth request with
      | `POST -> Some post
      | `GET  -> Some get
      | `PUT  -> Some put
      | `DELETE -> Some delete
      | `HEAD -> Some head
      | _ -> None
    in
    match selected with
    | None -> method_not_allowed ()
    | Some router ->
        match route ~router ~target ~request with
        | Some response -> response
        | exception Json_io.Http_error (status, message) ->
            Json_io.respond_string ~status message
        | exception exn ->
            Log.err (fun m -> m "unhandled exception: path=%s %s" target (Exn.to_string exn));
            Piaf.Response.of_string ~body:"Internal Server Error" `Internal_server_error
        | None ->
            let exists_elsewhere =
              List.exists all_routers ~f:(fun router ->
                match Routes.match' router ~target with
                | NoMatch -> false
                | _ -> true)
            in
            match exists_elsewhere with
            | true -> method_not_allowed ()
            | false -> not_found ()
  in
  let handler ({ Piaf.Server.ctx; request } : _ Piaf.Server.ctx) =
    let client_address = ctx.Piaf.Request_info.client_address in
    Middleware.log_request ~clock
      ~dispatch:(Cors.wrap ~dispatch:(dispatch ~client_address))
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
  let (_command : Piaf.Server.Command.t) = start_server ~sw ~env ~address:(`Tcp (Eio.Net.Ipaddr.V4.any, port)) ~handler ~error_handler in
  let (_command : Piaf.Server.Command.t) = start_server ~sw ~env ~address:(`Tcp (Eio.Net.Ipaddr.V6.any, port)) ~handler ~error_handler in
  Log.info (fun m -> m "Freetube started on port %d" port);
  Eio.Fiber.await_cancel ()
