open! Base

exception Http_error of Piaf.Status.t * string

let raise_http status message = raise (Http_error (status, message))

module Let_syntax = struct
  let ( let@! ) (result, (status, context)) f =
    match result with
    | Ok v -> f v
    | Error detail -> raise (Http_error (status, Printf.sprintf "%s: %s" context detail))
end

open Let_syntax

let respond_string ~status body =
  Piaf.Response.of_string ~body status

let respond_json ~status payload =
  let body = Yojson.Safe.to_string payload in
  let headers = Piaf.Headers.of_list [ "content-type", "application/json" ] in
  Piaf.Response.of_string ~headers ~body status

let read_body (request : Piaf.Request.t) =
  match Piaf.Body.to_string (Piaf.Request.body request) with
  | Ok s -> Ok s
  | Error e -> Error (Stdlib.Format.asprintf "%a" Piaf.Error.pp_hum e)

let parse_json payload =
  match Yojson.Safe.from_string payload with
  | json -> Ok json
  | exception exn -> Error (Exn.to_string exn)

let parse_of_yojson of_yojson json =
  match of_yojson json with
  | Ok v -> Ok v
  | Error msg -> Error msg

let parse_body ~context of_yojson request =
  let@! payload = read_body request, (`Bad_request, context) in
  let@! json = parse_json payload, (`Bad_request, context) in
  let@! v = parse_of_yojson of_yojson json, (`Bad_request, context) in
  v
