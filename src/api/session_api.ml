open! Base

(* POST /sessions request/response. Shared between the server and any
   client (incl. the browser plugin under src/plugin). *)

type source =
  | Youtube_id of string
  | Youtube_file of Uri.t
  | Url of Uri.t

let source_of_yojson = function
  | `List [ `String tag; `String value ] ->
      (match String.lowercase tag with
       | "youtube_id"   -> Ok (Youtube_id value)
       | "youtube_file" -> Ok (Youtube_file (Uri.of_string value))
       | "url"          -> Ok (Url (Uri.of_string value))
       | _ -> Error (Printf.sprintf "unknown source tag: %s" tag))
  | _ -> Error "expected [\"<tag>\", \"<value>\"] source"

let source_to_yojson = function
  | Youtube_id v   -> `List [ `String "youtube_id";   `String v ]
  | Youtube_file u -> `List [ `String "youtube_file"; `String (Uri.to_string u) ]
  | Url u          -> `List [ `String "url";          `String (Uri.to_string u) ]

type create_request = {
  source : source;
      [@of_yojson source_of_yojson] [@to_yojson source_to_yojson]
  sink : string option; [@default None]
  stream_format : Stream_format.t option; [@default None]
  vcodecs : string list option; [@default None]
  acodecs : string list option; [@default None]
  cookies : Cookies.t list option; [@default None]
} [@@deriving yojson { strict = false }]

type create_response = {
  session_id : string;
  url        : string;
} [@@deriving yojson]

type sink_summary = {
  kind          : string;
  friendly_name : string option;
  controllable  : bool;
} [@@deriving yojson]

type session_summary = {
  session_id   : string;
  created_at   : float;
  idle_seconds : float;
  sink         : sink_summary;
} [@@deriving yojson]

type sessions_response = { sessions : session_summary list }
[@@deriving yojson]

type sink_request_kind = [ `Url | `Airplay | `Dlna ]

let sink_kind_of_string = function
  | "url"     -> Ok `Url
  | "airplay" -> Ok `Airplay
  | "dlna"    -> Ok `Dlna
  | s -> Error (Printf.sprintf "unknown sink kind: %s" s)

let sink_kind_to_string = function
  | `Url -> "url"
  | `Airplay -> "airplay"
  | `Dlna -> "dlna"

let sink_request_kind_of_yojson = function
  | `String s -> sink_kind_of_string s
  | _ -> Error "expected string sink kind"

let sink_request_kind_to_yojson k = `String (sink_kind_to_string k)

type sink_request = {
  kind : sink_request_kind;
      [@of_yojson sink_request_kind_of_yojson]
      [@to_yojson sink_request_kind_to_yojson]
  device_id : string option; [@default None]
} [@@deriving yojson { strict = false }]
