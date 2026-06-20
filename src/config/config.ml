open! Base

type ip_version = [ `V4 | `V6 ] [@@deriving yojson]

type streaming = {
  prefetch_count : int;
  cache_capacity : int;
  live_window_seconds : int;
  live_edge_segments : int;
  default_segment_duration_us : int;
} [@@deriving yojson]

type network = {
  max_connections_per_host : int;
  max_redirects : int;
  ip_version : ip_version;
  file_chunk_size : int;
} [@@deriving yojson]

type video = {
  max_width : int;
  max_height : int;
} [@@deriving yojson]

type discovery = {
  scan_timeout_seconds : float;
  airplay_interval_seconds : float;
  dlna_interval_seconds : float;
} [@@deriving yojson]

type t = {
  listen_port : int;
  mdns_hostname : string;
  session_ttl_seconds : float;
  ntp_port : int;
  transcode : bool;
  max_ffmpeg_per_stream : int;
  gpu_device : string option;
  streaming : streaming;
  network : network;
  video : video;
  discovery : discovery;
} [@@deriving yojson]

let default = {
  listen_port = 5544;
  mdns_hostname = "freetube.local";
  session_ttl_seconds = 1800.0;
  ntp_port = 7010;
  transcode = false;
  max_ffmpeg_per_stream = 2;
  gpu_device = None;
  streaming = {
    prefetch_count = 3;
    cache_capacity = 6;
    live_window_seconds = 10800;
    live_edge_segments = 6;
    default_segment_duration_us = 5_000_000;
  };
  network = {
    max_connections_per_host = 4;
    max_redirects = 5;
    ip_version = `V4;
    file_chunk_size = 65536;
  };
  video = {
    max_width = 3840;
    max_height = 2160;
  };
  discovery = {
    scan_timeout_seconds = 5.0;
    airplay_interval_seconds = 60.0;
    dlna_interval_seconds = 60.0;
  };
}

let current : t ref = ref default

let get () = !current
