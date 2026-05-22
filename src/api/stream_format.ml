open! Base

type t = Hls | Dash
[@@deriving yojson, equal]

let to_string = function
  | Hls  -> "hls"
  | Dash -> "dash"

let of_string = function
  | "hls"  -> Some Hls
  | "dash" -> Some Dash
  | _      -> None
