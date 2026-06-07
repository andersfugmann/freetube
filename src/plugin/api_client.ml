open! Base

(** Typed client for the FreeTube HTTP API. All payload types live in
    [Api.*] and are shared with the server. *)

let server_url_key = "server_url"
let default_server = "http://freetube.local:5544"

let load_server ~k = Chrome.Storage.get_string ~key:server_url_key
                       ~default:default_server ~k

let save_server url = Chrome.Storage.set_string ~key:server_url_key ~value:url

let join base path =
  let b = String.rstrip ~drop:(Char.equal '/') base in
  let p = String.lstrip ~drop:(Char.equal '/') path in
  b ^ "/" ^ p

let parse_json_string s =
  match Yojson.Safe.from_string s with
  | json -> Ok json
  | exception exn -> Error (Exn.to_string exn)

let ( let* ) x f = match x with Ok v -> f v | Error _ as e -> e

let decode_body of_yojson body =
  let* json = parse_json_string body in
  of_yojson json

let get_devices ~server ~k =
  Chrome.Fetch.get ~url:(join server "/devices")
    ~k_ok:(fun body -> k (decode_body Device.list_response_of_yojson body))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let get_config ~server ~k =
  Chrome.Fetch.get ~url:(join server "/config")
    ~k_ok:(fun body -> k (decode_body Config.of_yojson body))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let put_config ~server ~config ~k =
  let body = Yojson.Safe.to_string (Config.to_yojson config) in
  Chrome.Fetch.send ~meth:"PUT" ~url:(join server "/config") ~body
    ~k_ok:(fun body -> k (decode_body Config.of_yojson body))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let create_session ~server ~req ~k =
  let body =
    Yojson.Safe.to_string (Api.Session_api.create_request_to_yojson req)
  in
  Chrome.Fetch.send ~meth:"POST" ~url:(join server "/sessions") ~body
    ~k_ok:(fun body -> k (decode_body Api.Session_api.create_response_of_yojson body))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let get_device_config ~server ~id ~k =
  Chrome.Fetch.get ~url:(join server (Printf.sprintf "/devices/%s/config" id))
    ~k_ok:(fun body ->
      k (Result.map (decode_body Device.of_yojson body) ~f:Option.some))
    ~k_err:(fun status body ->
      match status with
      | 404 -> k (Ok None)
      | _ -> k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let put_device_config ~server ~id ~cfg ~k =
  let body = Yojson.Safe.to_string (Device.to_yojson cfg) in
  Chrome.Fetch.send ~meth:"PUT" ~body
    ~url:(join server (Printf.sprintf "/devices/%s/config" id))
    ~k_ok:(fun _ -> k (Ok ()))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let pair_start ~server ~device_id ~k =
  let req : Api.Airplay_pairing.pair_start_request = { device_id } in
  let body =
    Yojson.Safe.to_string (Api.Airplay_pairing.pair_start_request_to_yojson req)
  in
  Chrome.Fetch.send ~meth:"POST" ~url:(join server "/airplay/pair") ~body
    ~k_ok:(fun body -> k (decode_body Api.Airplay_pairing.pair_start_response_of_yojson body))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))

let pair_finish ~server ~session_id ~pin ~k =
  let req : Api.Airplay_pairing.pair_finish_request = { session_id; pin } in
  let body =
    Yojson.Safe.to_string (Api.Airplay_pairing.pair_finish_request_to_yojson req)
  in
  Chrome.Fetch.send ~meth:"POST" ~url:(join server "/airplay/pair") ~body
    ~k_ok:(fun body -> k (decode_body Api.Airplay_pairing.pair_finish_response_of_yojson body))
    ~k_err:(fun status body ->
      k (Error (Printf.sprintf "HTTP %d: %s" status body)))
