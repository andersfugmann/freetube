open! Base

let handle_get (_ : Request.t) =
  Ok (Response.ok ~content_type:(Explicit "application/json")
        (Config.to_yojson (Config.get ()) |> Yojson.Safe.to_string))

let handle_put ~(app : _ App.t) request =
  let ( let* ) result f = Result.bind result ~f in
  let* body = Json_io.read_body request |> Result.map_error ~f:(fun (`Bad_param msg) -> `Bad_param msg) in
  let* json =
    match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception exn -> Error (`Bad_param (Exn.to_string exn))
  in
  let* cfg = Config.of_yojson json |> Result.map_error ~f:(fun msg -> `Bad_param msg) in
  let updated = Config_global.update ~fs:(Eio.Stdenv.fs app.env) (fun _ -> cfg) in
  Ok (Response.ok ~content_type:(Explicit "application/json")
        (Config.to_yojson updated |> Yojson.Safe.to_string))
