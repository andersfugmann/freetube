open! Base

type kind = Airplay | Dlna [@@deriving yojson]

type t = {
  id : string;
  friendly_name : string;
  video_codecs : Codec.Video.t list;
  audio_codecs : Codec.Audio.t list;
  vendor : Vendor.t; [@default Generic]
  is_static : bool; [@default false]
  kind : kind option; [@default None]
  address : string option; [@default None]
  port : int option; [@default None]
  control_url : string option; [@default None]
  transcode : bool; [@default false]
  stream_format : Stream_format.t; [@default Hls]
} [@@deriving yojson { strict = false }]
