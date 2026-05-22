open! Base

type t = Apple | Samsung | Lg | Generic
[@@deriving yojson, equal]

let to_string = function
  | Apple   -> "Apple"
  | Samsung -> "Samsung"
  | Lg      -> "Lg"
  | Generic -> "Generic"

(* Defaults applied at device discovery when we have no prior config.
   These are the codecs a stock device of that brand is expected to
   handle in practice — the user can narrow or widen them later from
   the plugin popup. *)
let default_video_codecs : t -> Codec.Video.t list = function
  | Apple   -> [ Avc; Hevc ]
  | Samsung -> [ Avc; Hevc; Vp9; Av1 ]
  | Lg      -> [ Avc; Hevc; Vp9; Av1 ]
  | Generic -> [ Avc; Hevc ]

let default_audio_codecs : t -> Codec.Audio.t list = function
  | Apple   -> [ Aac ]
  | Samsung -> [ Aac; Opus ]
  | Lg      -> [ Aac; Opus ]
  | Generic -> [ Aac ]
