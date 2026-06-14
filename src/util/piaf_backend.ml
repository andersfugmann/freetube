open! Base
type t = {
  env: Eio_unix.Stdenv.base;
  sw: Eio.Switch.t;
  wakeup: Eio.Condition.t;
  max_conn_per_host: int;
  pool: (string, (int * Piaf.Client.t list)) Hashtbl.t;
}
exception Http_failure of string

type response = Http_client.response

module Log = (val Log_src.src_log ~doc:"HTTP client backend (piaf)" Stdlib.__MODULE__)

let close_client c = try Piaf.Client.shutdown c with _ -> ()

let close t =
  let clients =
    Hashtbl.to_alist t.pool
    |> List.map ~f:snd
    |> List.map ~f:snd
    |> List.join
  in
  Hashtbl.clear t.pool;
  List.iter ~f:close_client clients

let init ~max_conn_per_host ~sw ~env () =
  let t =
    {
      env = (env :> Eio_unix.Stdenv.base);
      sw;
      max_conn_per_host;
      wakeup = Eio.Condition.create ();
      pool = Hashtbl.create (module String);
    }
  in
  Eio.Switch.on_release sw (fun () -> close t);
  t

let error_message e = Stdlib.Format.asprintf "%a" Piaf.Error.pp_hum e

let to_response (response : Piaf.Response.t) =
  match Piaf.Body.to_string response.body with
  | Error e -> raise (Http_failure (Printf.sprintf "body read: %s" (error_message e)))
  | Ok body ->
      {
        Http_client.status = Piaf.Status.to_code response.status;
        headers = Piaf.Headers.to_list response.headers;
        body;
      }
  | exception End_of_file ->
      raise (Http_failure "body read: unexpected end-of-file")
  | exception exn ->
      raise (Http_failure (Printf.sprintf "body read: %s" (Exn.to_string exn)))


(** Return scheme, host and port *)
let origin uri =
  Uri.with_uri ~path:None ~query:None ~fragment:None uri

(** Return the path and query parameters *)
let target_of uri =
  let uri = Uri.with_uri ~scheme:None ~host:None ~port:None ~userinfo:None uri in
  Uri.to_string uri

let client_config () =
  let base = Piaf.Config.default in
  { base with
    follow_redirects = true;
    max_redirects = (Config.get ()).network.max_redirects;
  }

let make_client t ~(ip_version:[ `V4 | `V6 ]) origin =
  let rec loop retry ip_version =
    let base = client_config () in
    let config =
      { base with prefer_ip_version = (ip_version :> [ `V4 | `V6 | `Both])}
    in
    let result =
      match Piaf.Client.create ~config ~sw:t.sw t.env origin with
      | Ok c -> Ok c
      | Error e -> Error (error_message e)
      | exception _ when Eio.Fiber.is_cancelled () ->
          raise (Http_failure "Fiber cancelled")
      | exception exn -> Error (Exn.to_string exn)
    in
    match result with
    | Ok c -> c
    | Error msg when retry ->
        Log.info (fun m -> m "Fallback to `Both for origin: %s (%s)" (Uri.to_string origin) msg);
        loop false `Both
    | Error msg ->
        raise (Http_failure msg)
  in
  loop true (ip_version :> [ `V4 | `V6 | `Both])

let get_client t ~ip_version origin =
  let key = Uri.to_string origin in
  let rec inner () =
    match Hashtbl.find t.pool key  with
    | Some (n, []) when n >= t.max_conn_per_host ->
      Eio.Condition.await_no_mutex t.wakeup;
      inner ()
    | Some (n, c :: cs) ->
      Hashtbl.set t.pool ~key ~data:(n, cs);
      c
    | _ ->
      Hashtbl.update t.pool key ~f:(function
          | None -> (1, [])
          | Some (n, cs) -> (n + 1, cs)
        );
      make_client t ~ip_version origin
  in
  inner ()

let return_client t origin client =
  let key = Uri.to_string origin in
  Hashtbl.change t.pool key ~f:(function
      | Some (n, cs) -> Some (n, client :: cs)
      | None ->
        close_client client;
        None
    );
  Eio.Condition.broadcast t.wakeup

let with_client t ~ip_version ~oneshot uri ~f =
  let origin = origin uri in
  let client, on_done = match oneshot with
    | true ->
      let client = make_client t ~ip_version origin in
      client, Piaf.Client.shutdown
    | false ->
      let client = get_client t ~ip_version origin in
      client, (return_client t origin)
  in
  Base.Exn.protect ~f:(fun () -> f client) ~finally:(fun () -> on_done client)

let request: t -> meth:Piaf.Method.t -> ip_version:[ `V4 | `V6] -> ?headers:(string * string) list -> ?oneshot:bool -> ?body:string -> Uri.t -> response =
  fun t ~meth ~ip_version ?headers ?(oneshot=false) ?body uri ->
  let f client =
    let target_str = target_of uri in
    let body = Option.map ~f:Piaf.Body.of_string body in
    match Piaf.Client.request client ?headers ?body ~meth target_str with
    | Error e -> raise (Http_failure (error_message e))
    | Ok r -> to_response r
  in
  with_client t ~ip_version ~oneshot uri ~f

let head t ~ip_version ?headers ?oneshot uri =
  request t ~meth:`HEAD ~ip_version ?headers ?oneshot uri

let get t ~ip_version ?headers ?oneshot uri =
  request t ~meth:`GET ~ip_version ?headers ?oneshot uri

let post t ~ip_version ?(headers=[]) ?content_type ?oneshot ~body uri =
  (* Inject content type into headers *)
  let headers =
    match content_type with
    | None -> headers
    | Some ct -> ("content-type", ct) :: headers
  in
  request t ~meth:`POST ~ip_version ~headers ?oneshot ~body uri
