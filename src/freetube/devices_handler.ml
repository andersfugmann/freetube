open! Base
open Devices
open Json_io.Let_syntax

let handle_list ~(app : _ App.t) =
  let devices = Device_store.all app.device_store in
  let body =
    Device.list_response_to_yojson { devices }
    |> Yojson.Safe.to_string
  in
  let headers = Piaf.Headers.of_list [ "content-type", "application/json" ] in
  Piaf.Response.of_string ~headers ~body `OK

let respond_string ~status body = Piaf.Response.of_string ~body status

let respond_json ~status payload =
  let headers = Piaf.Headers.of_list [ "content-type", "application/json" ] in
  Piaf.Response.of_string ~headers ~body:(Yojson.Safe.to_string payload) status

let handle_get_config ~(app : _ App.t) ~id =
  match Device_store.find app.device_store ~id with
  | None -> respond_string ~status:`Not_found "No per-device config"
  | Some cfg -> respond_json ~status:`OK (Device.to_yojson cfg)

let handle_put_config ~(app : _ App.t) ~id request =
  let@! payload = Json_io.read_body request, (`Bad_request, "Update device config") in
  let@! json = Json_io.parse_json payload, (`Bad_request, "Update device config") in
  let@! cfg = Json_io.parse_of_yojson Device.of_yojson json, (`Bad_request, "Update device config") in
  match String.equal cfg.id id with
  | false ->
      Json_io.raise_http `Bad_request
        (Printf.sprintf "Update device config: URL id %s does not match body id %s" id cfg.id)
  | true ->
      Device_store.save app.device_store cfg;
      respond_json ~status:`OK (Device.to_yojson cfg)

let handle_delete_config ~(app : _ App.t) ~id =
  Device_store.remove app.device_store ~id;
  respond_string ~status:`No_content ""
