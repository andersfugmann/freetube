open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA device description XML parsing" Stdlib.__MODULE__)

type service = {
  service_type : string;
  service_id : string;
  control_url : string;
  event_sub_url : string;
  scpd_url : string;
}

let host_of_uri uri =
  Uri.host (Uri.of_string uri) |> Option.value ~default:""

let origin_of_uri uri =
  match Uri.scheme uri, Uri.host uri with
  | Some scheme, Some host ->
      (match Uri.port uri with
       | Some port -> Printf.sprintf "%s://%s:%d" scheme host port
       | None -> Printf.sprintf "%s://%s" scheme host)
  | _ -> ""

let resolve_url ~base url =
  let url = String.strip url in
  let target = Uri.of_string url in
  match Uri.scheme target with
  | Some _ -> Uri.to_string target
  | None ->
      let base_uri = Uri.of_string base in
      let default_scheme =
        Uri.scheme base_uri |> Option.value ~default:"http"
      in
      Uri.resolve default_scheme base_uri target |> Uri.to_string

let first_member tag nodes =
  match Ezxmlm.members tag nodes with
  | first :: _ -> Ok first
  | [] -> Error (Printf.sprintf "Missing <%s>" tag)

let first_member_opt tag nodes =
  match Ezxmlm.members tag nodes with
  | first :: _ -> Some first
  | [] -> None

let member_text tag nodes =
  match Ezxmlm.members tag nodes with
  | first :: _ -> Ok (Ezxmlm.data_to_string first |> String.strip)
  | [] -> Error (Printf.sprintf "Missing <%s>" tag)

let member_text_opt tag nodes =
  match Ezxmlm.members tag nodes with
  | first :: _ -> Some (Ezxmlm.data_to_string first |> String.strip)
  | [] -> None

let parse_service base nodes =
  let ( let* ) x f = Result.bind x ~f in
  let* service_type = member_text "serviceType" nodes in
  let* service_id = member_text "serviceId" nodes in
  let* control_url = member_text "controlURL" nodes in
  let* event_sub_url = member_text "eventSubURL" nodes in
  let* scpd_url = member_text "SCPDURL" nodes in
  Ok { service_type; service_id;
       control_url = resolve_url ~base control_url;
       event_sub_url = resolve_url ~base event_sub_url;
       scpd_url = resolve_url ~base scpd_url }

let collect_results values ~f =
  let ( let* ) x fn = Result.bind x ~f:fn in
  List.fold values ~init:(Ok []) ~f:(fun acc value ->
      let* acc = acc in
      let* parsed = f value in
      Ok (parsed :: acc))
  |> Result.map ~f:List.rev

let parse ~location ~xml =
  let ( let* ) x f = Result.bind x ~f in
  let* (_, nodes) =
    Result.try_with (fun () -> Ezxmlm.from_string xml)
    |> Result.map_error
         ~f:(fun exn -> Printf.sprintf "Invalid device description XML: %s" (Exn.to_string exn))
  in
  let location_uri = Uri.of_string location in
  let location_base = origin_of_uri location_uri in
  let* () =
    match String.is_empty location_base with
    | true -> Error (Printf.sprintf "Invalid location URL: %s" location)
    | false -> Ok ()
  in
  let* root = first_member "root" nodes in
  let* device = first_member "device" root in
  let* device_type = member_text "deviceType" device in
  let* friendly_name = member_text "friendlyName" device in
  let* manufacturer = member_text "manufacturer" device in
  let* model_name = member_text "modelName" device in
  let* udn = member_text "UDN" device in
  let* service_list = first_member "serviceList" device in
  let service_nodes = Ezxmlm.members "service" service_list in
  let* services = collect_results service_nodes ~f:(parse_service location) in
  let icon_url =
    first_member_opt "iconList" device
    |> Option.bind ~f:(first_member_opt "icon")
    |> Option.bind ~f:(member_text_opt "url")
    |> Option.map ~f:(resolve_url ~base:location)
  in
  let service_types = List.map services ~f:(fun s -> s.service_type) in
  match
    List.find services ~f:(fun service ->
      String.is_substring service.service_type ~substring:"AVTransport")
  with
  | Some service ->
      Ok (Dlna.Client.create
            ~friendly_name ~udn ~control_url:service.control_url
            ~device_type ~manufacturer ~model_name ?icon_url
            ~location_base ~services:service_types
            ~address:(host_of_uri location_base) ())
  | None ->
      Error "Device description does not expose AVTransport service"

let%test "resolve_url keeps absolute URLs" =
  String.equal
    (resolve_url ~base:"http://device.local:1400/xml/device_description.xml"
       "https://example.test/control")
    "https://example.test/control"

let%test "resolve_url handles absolute paths" =
  String.equal
    (resolve_url ~base:"http://device.local:1400/xml/device_description.xml"
       "/MediaRenderer/AVTransport/Control")
    "http://device.local:1400/MediaRenderer/AVTransport/Control"

let%test "resolve_url handles relative paths" =
  String.equal
    (resolve_url ~base:"http://device.local:1400/xml/device_description.xml"
       "MediaRenderer/AVTransport/Control")
    "http://device.local:1400/xml/MediaRenderer/AVTransport/Control"
