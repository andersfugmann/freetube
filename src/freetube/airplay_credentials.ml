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

let mkdir_p dir =
  let rec loop dir =
    match Stdlib.Sys.file_exists dir with
    | true -> ()
    | false ->
        loop (Stdlib.Filename.dirname dir);
        (try Stdlib.Sys.mkdir dir 0o700 with Sys_error _ -> ())
  in
  loop dir

let load ~pairing_id =
  let path = path_for ~pairing_id in
  match Stdlib.Sys.file_exists path with
  | false -> None
  | true ->
      let contents = Stdio.In_channel.read_all path in
      match Yojson.Safe.from_string contents |> Airplay_protocol.Pairing.credentials_of_yojson with
      | Ok entry -> Some entry
      | Error error ->
          Log.warn (fun m -> m "Failed to parse %s: %s" path error);
          None

let save (entry : Airplay_protocol.Pairing.credentials) =
  let path = path_for ~pairing_id:(Airplay_protocol.Pairing.pairing_id entry) in
  mkdir_p (Stdlib.Filename.dirname path);
  let tmp = path ^ ".tmp" in
  Stdio.Out_channel.write_all tmp
    ~data:(Airplay_protocol.Pairing.credentials_to_yojson entry |> Yojson.Safe.to_string);
  Stdlib.Sys.rename tmp path
