open! Base

module Client = struct
  type t =
    | Airplay of Airplay.Client.t
    | Dlna of Dlna.Client.t
    | Url
  [@@deriving yojson]
end

type t = {
  id : string;
  friendly_name : string;
  client : Client.t;
  video_codecs : Codec.Video.t list;
  audio_codecs : Codec.Audio.t list;
  vendor : Api.Vendor.t; [@default Generic]
  transcode : bool; [@default false]
  max_width : int; [@default 3840]
  max_height : int; [@default 2160]
  stream_format : Api.Stream_format.t; [@default Hls]
  last_seen : float;
} [@@deriving yojson { strict = false }]

let of_airplay ~video_codecs ~audio_codecs ~vendor ~transcode ~max_width ~max_height ~stream_format ~last_seen
      (client : Airplay.Client.t) =
  { id = client.pairing_id;
    friendly_name = Airplay.Client.friendly_name client;
    client = Airplay client;
    video_codecs; audio_codecs; vendor; transcode; max_width; max_height; stream_format; last_seen }

let of_dlna ~video_codecs ~audio_codecs ~vendor ~transcode ~max_width ~max_height ~stream_format ~last_seen
      (client : Dlna.Client.t) =
  { id = client.udn;
    friendly_name = client.friendly_name;
    client = Dlna client;
    video_codecs; audio_codecs; vendor; transcode; max_width; max_height; stream_format; last_seen }

let of_url ~video_codecs ~audio_codecs ~transcode ~max_width ~max_height ~stream_format =
  { id = "url";
    friendly_name = "url";
    client = Url;
    video_codecs; audio_codecs;
    vendor = Generic; transcode; max_width; max_height; stream_format; last_seen = 0. }

type list_response = { devices : t list } [@@deriving yojson]

let kind = function
  | { client = Airplay _; _ } -> "airplay"
  | { client = Dlna _; _ } -> "dlna"
  | { client = Url; _ } -> "url"
