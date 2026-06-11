open! Base

let handle_get (_ : Piaf.Request.t) =
  Json_io.respond_json ~status:`OK (Config.to_yojson (Config.get ()))

let handle_put ~(app : _ App.t) request =
  let body =
    match Json_io.read_body request with
    | Ok s -> s
    | Error msg -> Json_io.raise_http `Bad_request msg
  in
  let json = Yojson.Safe.from_string body in
  match Config.of_yojson json with
  | Error msg -> Json_io.raise_http `Bad_request msg
  | Ok cfg ->
    let updated = Config_global.update ~fs:(Eio.Stdenv.fs app.env) (fun _ -> cfg) in
    Json_io.respond_json ~status:`OK (Config.to_yojson updated)
