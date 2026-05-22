open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Request logging middleware" Stdlib.__MODULE__)

let body_bytes (response : Piaf.Response.t) =
  match Piaf.Body.length response.body with
  | `Fixed n -> Some (Int64.to_int_exn n)
  | _ ->
      Piaf.Headers.get response.headers "content-length"
      |> Option.bind ~f:(fun v -> Int.of_string_opt (String.strip v))

let log_request ~clock ~dispatch (request : Piaf.Request.t) =
  let meth = Piaf.Method.to_string (Piaf.Request.meth request) in
  let path = Uri.path (Piaf.Request.uri request) in
  let t0 = Eio.Time.now clock in
  let response = dispatch request in
  let t1 = Eio.Time.now clock in
  let elapsed_ms = (t1 -. t0) *. 1000.0 in
  let status = Piaf.Status.to_code response.Piaf.Response.status in
  let extra =
    match body_bytes response with
    | Some bytes -> Printf.sprintf " bytes=%d" bytes
    | None -> ""
  in
  Log.info (fun m ->
    m "%s %s status=%d elapsed=%.2fms%s" meth path status elapsed_ms extra);
  response
