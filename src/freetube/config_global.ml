open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Global configuration" Stdlib.__MODULE__)

let path () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.config_dir xdg) "freetube/config.json"

let save ~fs t =
  let p = path () in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 Eio.Path.(fs / Stdlib.Filename.dirname p);
  let json = Config.to_yojson t |> Yojson.Safe.pretty_to_string in
  Eio.Path.save Eio.Path.(fs / p) json ~create:(`Or_truncate 0o600)

let delete ~fs path =
  try Eio.Path.unlink Eio.Path.(fs / path) with _ -> ()

let load_existing_or_default ~fs path =
  match
    Result.try_with (fun () -> Eio.Path.load Eio.Path.(fs / path))
    |> Result.map ~f:(fun s -> Yojson.Safe.from_string s |> Config.of_yojson)
  with
  | Ok (Ok t) -> t
  | Ok (Error msg) ->
      Log.warn (fun m ->
        m "Failed to parse %s: %s — deleting and using defaults" path msg);
      delete ~fs path;
      Config.default
  | Error exn ->
      Log.warn (fun m ->
        m "Failed to read %s: %s — deleting and using defaults"
          path (Exn.to_string exn));
      delete ~fs path;
      Config.default

let update ~fs f =
  let t = f (Config.get ()) in
  Config.current := t;
  save ~fs t;
  t

let load ~fs () =
  let path = path () in
  let t =
    match Eio.Path.is_file Eio.Path.(fs / path) with
    | false ->
      save ~fs Config.default;
      Config.default
    | true -> load_existing_or_default ~fs path
  in
  Config.current := t;
  t
