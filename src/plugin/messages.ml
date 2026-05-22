open! Base

(** Messages exchanged between the content script and the background
    service worker via [chrome.runtime.sendMessage]. All wire-encoded
    as JSON through [ppx_deriving_yojson]. *)

type cast = {
  video_id : string;
  device_id : string;
} [@@deriving yojson]

type request =
  | List_devices
  | Cast of cast
[@@deriving yojson]

type cast_ok = {
  session_id : string;
  url : string;
} [@@deriving yojson]

type response =
  | Devices of Device.list_response
  | Cast_ok of cast_ok
  | Err of string
[@@deriving yojson]
