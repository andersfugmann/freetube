open! Base

type t =
  | Dash_xml
  | Hls_m3u8
  | Video_mp4
  | Video_webm

let of_filename filename =
  match Stdlib.Filename.extension filename |> String.lowercase with
  | ".mp4" -> Some Video_mp4
  | ".webm" -> Some Video_webm
  | ".m3u8" -> Some Hls_m3u8
  | ".mpd" -> Some Dash_xml
  | _ -> None

let to_string = function
  | Dash_xml -> "application/dash+xml"
  | Hls_m3u8 -> "application/vnd.apple.mpegurl"
  | Video_mp4 -> "video/mp4"
  | Video_webm -> "video/webm"
