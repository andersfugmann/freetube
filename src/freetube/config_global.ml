open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Global configuration" Stdlib.__MODULE__)

let path () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.config_dir xdg) "freetube/config.json"

let save t =
  let p = path () in
  Mkdir_p.ensure (Stdlib.Filename.dirname p);
  let json = Config.to_yojson t |> Yojson.Safe.pretty_to_string in
  Stdio.Out_channel.write_all p ~data:json

let update f =
  let t = f (Config.get ()) in
  Config.current := t;
  save t;
  t

let load () =
  let path = path () in
  let t =
    match Stdlib.Sys.file_exists path with
    | false ->
      save Config.default;
      Config.default
    | true ->
      match
        Result.try_with (fun () -> Stdio.In_channel.read_all path)
        |> Result.map ~f:(fun s -> Yojson.Safe.from_string s |> Config.of_yojson)
      with
      | Ok (Ok t) -> t
      | Ok (Error msg) ->
        Log.warn (fun m ->
          m "Failed to parse %s: %s — deleting and using defaults" path msg);
        (try Stdlib.Sys.remove path with _ -> ());
        Config.default
      | Error exn ->
        Log.warn (fun m ->
          m "Failed to read %s: %s — deleting and using defaults"
            path (Exn.to_string exn));
        (try Stdlib.Sys.remove path with _ -> ());
        Config.default
  in
  Config.current := t;
  t
