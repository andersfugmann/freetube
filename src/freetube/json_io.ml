open! Base

module Let_syntax = struct
  let ( let@! ) (result, context) f =
    match result with
    | Ok value -> f value
    | Error detail -> Error (`Bad_param (Printf.sprintf "%s: %s" context detail))
end

open Let_syntax

let read_body request =
  Ok request.Request.body

let parse_json payload =
  match Yojson.Safe.from_string payload with
  | json -> Ok json
  | exception exn -> Error (Exn.to_string exn)

let parse_of_yojson of_yojson json =
  match of_yojson json with
  | Ok v -> Ok v
  | Error msg -> Error msg

let parse_body ~context of_yojson request =
  let@! payload = read_body request, context in
  let@! json = parse_json payload, context in
  let@! value = parse_of_yojson of_yojson json, context in
  Ok value
