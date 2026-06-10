open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay credential persistence" Stdlib.__MODULE__)

(* Persistence for AirPlay pairing credentials. The protocol library models
   the credential value (`Airplay_protocol.Pairing.credentials`); freetube decides where
   and when it lives on disk. *)

let data_dir () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.data_dir xdg) "freetube/airplay"

let path_for ~pairing_id =
  Stdlib.Filename.concat (data_dir ()) (pairing_id ^ ".json")

let mkdir_p ~fs dir =
  let rec loop dir =
    match Eio.Path.is_directory Eio.Path.(fs / dir) with
    | true -> ()
    | false ->
      loop (Stdlib.Filename.dirname dir);
      (try Eio.Path.mkdir Eio.Path.(fs / dir) ~perm:0o700 with Eio.Io _ -> ())
  in
  loop dir

let load ~fs ~pairing_id =
  let path = path_for ~pairing_id in
  match Eio.Path.is_file Eio.Path.(fs / path) with
  | false -> None
  | true ->
    let contents = Eio.Path.load Eio.Path.(fs / path) in
    match Yojson.Safe.from_string contents |> Airplay_protocol.Pairing.credentials_of_yojson with
    | Ok entry -> Some entry
    | Error error ->
        Log.warn (fun m -> m "Failed to parse %s: %s" path error);
        None

let save ~fs entry =
  let path = path_for ~pairing_id:(Airplay_protocol.Pairing.pairing_id entry) in
  mkdir_p ~fs (Stdlib.Filename.dirname path);
  let tmp = path ^ ".tmp" in
  let data = Airplay_protocol.Pairing.credentials_to_yojson entry |> Yojson.Safe.to_string in
  Eio.Path.save Eio.Path.(fs / tmp) data ~create:(`Or_truncate 0o600);
  Eio.Path.rename Eio.Path.(fs / tmp) Eio.Path.(fs / path)
