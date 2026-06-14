open! Base
open Util

module Cmd = Cmdliner.Cmd
module Arg = Cmdliner.Arg
module Term = Cmdliner.Term

let die fmt =
  Printf.ksprintf (fun s -> Stdlib.prerr_endline s; Stdlib.exit 1) fmt

let post_json client ~server ~path body =
  let uri = Uri.of_string (server ^ path) in
  let payload = Yojson.Safe.to_string body in
  let response =
    Http_client.post client ~ip_version:`V4 ~content_type:"application/json"
      ~oneshot:true ~body:payload uri
  in
  response.status, response.body

(* ── devices / sessions ────────────────────────────────────────────── *)

let get_and_print ~server ~path =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Http_client.init
      ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
      ~sw ~env ()
  in
  let uri = Uri.of_string (server ^ path) in
  let response = Http_client.get client ~ip_version:`V4 uri in
  match response.status with
  | 200 ->
      response.body
      |> Yojson.Safe.from_string
      |> Yojson.Safe.pretty_to_string
      |> Stdlib.print_endline
  | status -> die "Error %d: %s" status response.body

(* ── stream ────────────────────────────────────────────────────────── *)

type stream_response = {
  url : string;
  session_id : string;
} [@@deriving of_yojson { strict = false }]

let source_to_yojson s =
  match
    String.is_prefix s ~prefix:"http://" || String.is_prefix s ~prefix:"https://"
  with
  | true -> `List [ `String "youtube_file"; `String s ]
  | false -> `List [ `String "youtube_id"; `String s ]

let run_stream ~server ~source ~sink ~vcodecs ~acodecs ~format =
  let codecs_field name = function
    | [] -> []
    | xs -> [ name, `List (List.map xs ~f:(fun s -> `String s)) ]
  in
  let sink_json = match sink with Some d -> `String d | None -> `Null in
  let format_field = match format with
    | "dash" -> [ "stream_format", `List [`String "Dash"] ]
    | _ -> []
  in
  let body =
    `Assoc
      ([ "source", source_to_yojson source; "sink", sink_json ]
       @ format_field
       @ codecs_field "vcodecs" vcodecs
       @ codecs_field "acodecs" acodecs)
    |> Yojson.Safe.to_string
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Http_client.init
      ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
      ~sw ~env ()
  in
  match post_json client ~server ~path:"/sessions" (Yojson.Safe.from_string body) with
  | 200, body ->
      (match stream_response_of_yojson (Yojson.Safe.from_string body) with
       | Ok { url; _ } ->
         let url = match format with
           | "dash" -> String.substr_replace_all url
                         ~pattern:"master.m3u8" ~with_:"dash.mpd"
           | _ -> url
         in
         Stdlib.print_endline url
       | Error e -> die "bad response: %s" e)
  | code, body -> die "stream failed: %d %s" code body

(* ── play_file ─────────────────────────────────────────────────────── *)

let run_play_file ~server ~device_id ~filename =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Http_client.init
      ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
      ~sw ~env ()
  in
  let req : Api.Session_api.create_request =
    { source = Url (Uri.of_string filename);
      sink = Some device_id;
      stream_format = None;
      vcodecs = None;
      acodecs = None;
      cookies = None }
  in
  let body = Api.Session_api.create_request_to_yojson req in
  match post_json client ~server ~path:"/sessions" body with
  | 200, body -> Stdlib.print_endline body
  | status, body -> die "Error %d: %s" status body

(* ── airplay_pair ──────────────────────────────────────────────────── *)

let prompt_for_pin () =
  Stdlib.print_string "Enter PIN displayed on the device: ";
  Stdlib.flush Stdlib.stdout;
  match Stdlib.input_line Stdlib.stdin |> String.strip with
  | "" -> failwith "empty PIN"
  | pin -> pin

let run_airplay_pair ~server ~device_id =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Http_client.init
      ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
      ~sw ~env ()
  in
  let start_request : Api.Airplay_pairing.pair_start_request = { device_id } in
  match
    post_json client ~server ~path:"/airplay/pair"
      (Api.Airplay_pairing.pair_start_request_to_yojson start_request)
  with
  | n, payload when n <> 200 -> die "Server returned %d: %s" n payload
  | _, payload ->
      let session_id =
        match
          Api.Airplay_pairing.pair_start_response_of_yojson
            (Yojson.Safe.from_string payload)
        with
        | Ok response -> response.session_id
        | Error error -> die "Failed to parse pair start response: %s" error
      in
      Stdlib.print_endline
        (Printf.sprintf "PIN displayed on %s. Session %s." device_id session_id);
      let pin = prompt_for_pin () in
      let finish_request : Api.Airplay_pairing.pair_finish_request =
        { session_id; pin }
      in
      (match
         post_json client ~server ~path:"/airplay/pair"
           (Api.Airplay_pairing.pair_finish_request_to_yojson finish_request)
       with
       | n, payload when n <> 200 -> die "Server returned %d: %s" n payload
       | _, payload -> Stdlib.print_endline payload)

(* ── command-line interface ────────────────────────────────────────── *)

let server_arg =
  let doc = "FreeTube server base URL." in
  Arg.(value & opt string "http://freetube.local:5544"
       & info [ "s"; "server" ] ~docv:"URL" ~doc)

let devices_cmd =
  let run server = get_and_print ~server ~path:"/devices" in
  Cmd.v (Cmd.info "devices" ~doc:"List discovered cast devices.")
    Term.(const run $ server_arg)

let sessions_cmd =
  let run server = get_and_print ~server ~path:"/sessions" in
  Cmd.v (Cmd.info "sessions" ~doc:"List live sessions.")
    Term.(const run $ server_arg)

let stream_cmd =
  let source =
    Arg.(required & pos 0 (some string) None
         & info [] ~docv:"VIDEO_ID|URL"
             ~doc:"YouTube video id or a streams URL.")
  in
  let sink =
    Arg.(value & opt (some string) None
         & info [ "sink" ] ~docv:"DEVICE" ~doc:"Target device id.")
  in
  let vcodecs =
    Arg.(value & opt (list string) []
         & info [ "vcodecs" ] ~docv:"C1,C2" ~doc:"Override video codecs.")
  in
  let acodecs =
    Arg.(value & opt (list string) []
         & info [ "acodecs" ] ~docv:"C1,C2" ~doc:"Override audio codecs.")
  in
  let format =
    Arg.(value & opt string "hls"
         & info [ "format" ] ~docv:"FORMAT"
             ~doc:"Stream format: hls (default) or dash.")
  in
  let run server source sink vcodecs acodecs format =
    run_stream ~server ~source ~sink ~vcodecs ~acodecs ~format
  in
  Cmd.v (Cmd.info "stream" ~doc:"Create a streaming session and print its URL.")
    Term.(const run $ server_arg $ source $ sink $ vcodecs $ acodecs $ format)

let airplay_pair_cmd =
  let device_id =
    Arg.(required & pos 0 (some string) None
         & info [] ~docv:"DEVICE_ID" ~doc:"AirPlay device id (from devices).")
  in
  let run server device_id = run_airplay_pair ~server ~device_id in
  Cmd.v
    (Cmd.info "airplay_pair"
       ~doc:"Pair with an AirPlay device using its on-screen PIN.")
    Term.(const run $ server_arg $ device_id)

let play_file_cmd =
  let device_id =
    Arg.(required & pos 0 (some string) None
         & info [] ~docv:"DEVICE_ID" ~doc:"Target device id.")
  in
  let filename =
    Arg.(required & pos 1 (some string) None
         & info [] ~docv:"FILENAME" ~doc:"File to play.")
  in
  let run server device_id filename =
    run_play_file ~server ~device_id ~filename
  in
  Cmd.v (Cmd.info "play_file" ~doc:"Play a local file on a device (legacy).")
    Term.(const run $ server_arg $ device_id $ filename)

let () =
  let doc = "Command-line client for the FreeTube server." in
  let info = Cmd.info "freetube_client" ~version:"0.1.0" ~doc in
  let group =
    Cmd.group info
      [ devices_cmd; stream_cmd; sessions_cmd; airplay_pair_cmd; play_file_cmd ]
  in
  Stdlib.exit (Cmd.eval group)
