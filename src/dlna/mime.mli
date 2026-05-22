open! Base

type t =
  | Dash_xml
  | Hls_m3u8
  | Video_mp4
  | Video_webm

(* Classify by file extension; [None] for unsupported types. *)
val of_filename : string -> t option

val to_string : t -> string
