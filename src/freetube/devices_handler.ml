open! Base
open Devices
open Json_io.Let_syntax

let handle_list ~(app : _ App.t) =
  let devices = Device_store.all app.device_store in
  let body =
    Device.list_response_to_yojson { devices }
    |> Yojson.Safe.to_string
  in
  Ok (Response.ok ~content_type:(Explicit "application/json") body)

let respond_string body =
  Response.ok ~content_type:No_content_type body

let respond_json payload =
  Response.ok ~content_type:(Explicit "application/json")
    (Yojson.Safe.to_string payload)

let handle_get_config ~(app : _ App.t) ~id =
  match Device_store.find app.device_store ~id with
  | None -> Error `Not_found
  | Some cfg -> Ok (respond_json (Device.to_yojson cfg))

let handle_put_config ~(app : _ App.t) ~id request =
  let@! payload = Json_io.read_body request, "Update device config" in
  let@! json = Json_io.parse_json payload, "Update device config" in
  let@! cfg = Json_io.parse_of_yojson Device.of_yojson json, "Update device config" in
  match String.equal cfg.id id with
  | false ->
      Error (`Bad_param
               (Printf.sprintf "Update device config: URL id %s does not match body id %s" id cfg.id))
  | true ->
      Device_store.save ~fs:(Eio.Stdenv.fs app.env) app.device_store cfg;
      Ok (respond_json (Device.to_yojson cfg))

let handle_delete_config ~(app : _ App.t) ~id =
  Device_store.remove ~fs:(Eio.Stdenv.fs app.env) app.device_store ~id;
  Ok (Response.no_content ())
