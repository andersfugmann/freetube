open! Base
open Util

module Log = (val Log_src.src_log ~doc:"High-level AirPlay playback commands" Stdlib.__MODULE__)

type play_params = {
  content_location : string;
  start_position : float;
}

let format_float value =
  let trimmed =
    Stdlib.Printf.sprintf "%.6f" value |> String.rstrip ~drop:(Char.equal '0')
  in
  match String.is_suffix trimmed ~suffix:"." with
  | true -> trimmed ^ "0"
  | false -> trimmed

let build_play_request params =
  {
    Rtsp.method_ = "POST";
    path = "/play";
    headers = [ "Content-Type", "text/parameters" ];
    body =
      "Content-Location: "
      ^ params.content_location
      ^ "\nStart-Position: "
      ^ format_float params.start_position
      ^ "\n";
  }

let build_scrub_request ~position =
  {
    Rtsp.method_ = "POST";
    path = "/scrub?position=" ^ format_float position;
    headers = [];
    body = "";
  }

let build_stop_request () =
  { Rtsp.method_ = "POST"; path = "/stop"; headers = []; body = "" }

let build_rate_request ~rate =
  {
    Rtsp.method_ = "POST";
    path = "/rate?value=" ^ format_float rate;
    headers = [];
    body = "";
  }
