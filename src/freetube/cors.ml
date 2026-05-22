open! Base

(** Permissive CORS middleware so the browser plugin can talk to the FreeTube server. *)

let allow_headers =
  [ "content-type"; "accept" ]
  |> String.concat ~sep:", "

let allow_methods =
  [ "GET"; "POST"; "PUT"; "DELETE"; "HEAD"; "OPTIONS" ]
  |> String.concat ~sep:", "

let cors_headers ~origin =
  let allow_origin = Option.value origin ~default:"*" in
  [ "access-control-allow-origin", allow_origin
  ; "access-control-allow-methods", allow_methods
  ; "access-control-allow-headers", allow_headers
  ; "access-control-max-age", "600"
  ; "vary", "Origin"
  ]

let origin_of (request : Piaf.Request.t) =
  Piaf.Headers.get (Piaf.Request.headers request) "origin"

let add_to_response ~origin (response : Piaf.Response.t) =
  let headers = cors_headers ~origin in
  let merged =
    List.fold headers ~init:(Piaf.Response.headers response)
      ~f:(fun acc (k, v) -> Piaf.Headers.add_unless_exists acc k v)
  in
  Piaf.Response.with_ response ~body:(Piaf.Response.body response) ~headers:merged

let preflight_response ~origin =
  let headers = Piaf.Headers.of_list (cors_headers ~origin) in
  Piaf.Response.create ~headers `No_content

let wrap ~dispatch (request : Piaf.Request.t) =
  let origin = origin_of request in
  match Piaf.Request.meth request with
  | `OPTIONS -> preflight_response ~origin
  | _ -> add_to_response ~origin (dispatch request)
