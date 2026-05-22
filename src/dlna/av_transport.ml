open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA AVTransport SOAP helpers" Stdlib.__MODULE__)

let av_transport_service = "urn:schemas-upnp-org:service:AVTransport:1"

type transport_state =
  | Playing
  | Stopped
  | Paused
  | Transitioning
  | No_media

type position_info = {
  track_duration : string;
  rel_time : string;
  abs_time : string;
  track_uri : string;
}

type upnp_error = {
  error_code : int;
  error_description : string;
}

let escape_xml value =
  value
  |> String.to_list
  |> List.map ~f:(function
       | '&' -> "&amp;"
       | '<' -> "&lt;"
       | '>' -> "&gt;"
       | '\'' -> "&apos;"
       | '"' -> "&quot;"
       | char -> String.of_char char)
  |> String.concat ~sep:""

let soap_headers action_name =
  [
    ("Content-Type", "text/xml; charset=\"utf-8\"");
    ("SOAPACTION", Printf.sprintf "\"%s#%s\"" av_transport_service action_name);
  ]

let soap_body action_name arguments =
  String.concat ~sep:""
    [
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>";
      "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" ";
      "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">";
      "<s:Body>";
      "<u:";
      action_name;
      " xmlns:u=\"";
      av_transport_service;
      "\">";
      arguments;
      "</u:";
      action_name;
      ">";
      "</s:Body>";
      "</s:Envelope>";
    ]

let action action_name arguments = soap_body action_name arguments, soap_headers action_name

let set_av_transport_uri ~control_url:_ ~uri ~metadata =
  let arguments =
    String.concat ~sep:""
      [
        "<InstanceID>0</InstanceID>";
        "<CurrentURI>";
        escape_xml uri;
        "</CurrentURI>";
        "<CurrentURIMetaData>";
        escape_xml metadata;
        "</CurrentURIMetaData>";
      ]
  in
  action "SetAVTransportURI" arguments

let play ~control_url:_ =
  action "Play" "<InstanceID>0</InstanceID><Speed>1</Speed>"

let pause ~control_url:_ = action "Pause" "<InstanceID>0</InstanceID>"
let stop ~control_url:_ = action "Stop" "<InstanceID>0</InstanceID>"

let seek ~control_url:_ ~target =
  let arguments =
    String.concat ~sep:""
      [
        "<InstanceID>0</InstanceID>";
        "<Unit>REL_TIME</Unit>";
        "<Target>";
        escape_xml target;
        "</Target>";
      ]
  in
  action "Seek" arguments

let get_position_info ~control_url:_ =
  action "GetPositionInfo" "<InstanceID>0</InstanceID>"

let get_transport_info ~control_url:_ =
  action "GetTransportInfo" "<InstanceID>0</InstanceID>"

let rec find_first_tag tag nodes =
  match Ezxmlm.members tag nodes with
  | first :: _ -> Some first
  | [] ->
      nodes
      |> List.find_map ~f:(function
           | `Data _ -> None
           | `El (_, children) -> find_first_tag tag children)

let find_first_text tag nodes =
  find_first_tag tag nodes |> Option.map ~f:Ezxmlm.data_to_string
  |> Option.map ~f:String.strip

let parse_xml xml =
  match Result.try_with (fun () -> Ezxmlm.from_string xml) with
  | Ok (_, nodes) -> Some nodes
  | Error exn ->
      Log.debug (fun message -> message "Failed to parse SOAP XML: %s" (Exn.to_string exn));
      None

let parse_upnp_error xml =
  match parse_xml xml with
  | None -> None
  | Some nodes ->
      let code = find_first_text "errorCode" nodes in
      let description = find_first_text "errorDescription" nodes in
      (match code, description with
       | Some code, Some error_description ->
           (match Result.try_with (fun () -> Int.of_string code) with
            | Ok error_code -> Some { error_code; error_description }
            | Error _ -> None)
       | _ -> None)

let unknown_response_error message =
  { error_code = 0; error_description = message }

let parse_transport_state xml =
  match parse_upnp_error xml with
  | Some error -> Error error
  | None ->
      (match parse_xml xml |> Option.bind ~f:(find_first_text "CurrentTransportState") with
       | Some "PLAYING" -> Ok Playing
       | Some "STOPPED" -> Ok Stopped
       | Some "PAUSED_PLAYBACK"
       | Some "PAUSED_RECORDING" -> Ok Paused
       | Some "TRANSITIONING" -> Ok Transitioning
       | Some "NO_MEDIA_PRESENT" -> Ok No_media
       (* Vendor-specific states (e.g. LG's "LG_TRANSITIONING") embed a known
          keyword; match on the substring so playback isn't treated as failed. *)
       | Some state when String.is_substring state ~substring:"TRANSITIONING" ->
           Ok Transitioning
       | Some state when String.is_substring state ~substring:"PLAYING" -> Ok Playing
       | Some state ->
           Error
             (unknown_response_error
                (Printf.sprintf "Unknown transport state: %s" state))
       | None -> Error (unknown_response_error "Missing CurrentTransportState"))

let parse_position_info xml =
  match parse_upnp_error xml with
  | Some error -> Error error
  | None ->
      (match parse_xml xml with
       | None -> Error (unknown_response_error "Invalid position info XML")
       | Some nodes ->
           let field name = find_first_text name nodes in
           (match field "TrackDuration", field "RelTime", field "AbsTime", field "TrackURI" with
            | Some track_duration, Some rel_time, Some abs_time, Some track_uri ->
                Ok { track_duration; rel_time; abs_time; track_uri }
            | _ -> Error (unknown_response_error "Missing position info fields")))

let%test "parse_transport_state extracts playing state" =
  let xml =
    String.concat ~sep:""
      [
        "<?xml version=\"1.0\"?>";
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">";
        "<s:Body>";
        "<u:GetTransportInfoResponse xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">";
        "<CurrentTransportState>PLAYING</CurrentTransportState>";
        "<CurrentTransportStatus>OK</CurrentTransportStatus>";
        "<CurrentSpeed>1</CurrentSpeed>";
        "</u:GetTransportInfoResponse>";
        "</s:Body>";
        "</s:Envelope>";
      ]
  in
  match parse_transport_state xml with
  | Ok Playing -> true
  | _ -> false

let%test "parse_upnp_error extracts error details" =
  let xml =
    String.concat ~sep:""
      [
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">";
        "<s:Body><s:Fault><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\">";
        "<errorCode>714</errorCode><errorDescription>Illegal MIME-Type</errorDescription>";
        "</UPnPError></detail></s:Fault></s:Body></s:Envelope>";
      ]
  in
  match parse_upnp_error xml with
  | Some { error_code = 714; error_description } ->
      String.equal error_description "Illegal MIME-Type"
  | Some _
  | None -> false
