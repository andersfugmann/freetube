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

let decode ~path contents =
  match Yojson.Safe.from_string contents |> Airplay_protocol.Pairing.credentials_of_yojson with
  | Ok entry -> Some entry
  | Error error ->
      Log.warn (fun m -> m "Failed to parse %s: %s" path error);
      None

let load ~fs ~pairing_id =
  let path = path_for ~pairing_id in
  match Eio.Path.is_file Eio.Path.(fs / path) with
  | false -> None
  | true -> Eio.Path.load Eio.Path.(fs / path) |> decode ~path

let save ~fs entry =
  let path = path_for ~pairing_id:(Airplay_protocol.Pairing.pairing_id entry) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 Eio.Path.(fs / Stdlib.Filename.dirname path);
  let tmp = path ^ ".tmp" in
  let data = Airplay_protocol.Pairing.credentials_to_yojson entry |> Yojson.Safe.to_string in
  Eio.Path.save Eio.Path.(fs / tmp) data ~create:(`Or_truncate 0o600);
  Eio.Path.rename Eio.Path.(fs / tmp) Eio.Path.(fs / path)
