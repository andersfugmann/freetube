open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Per-device config file store" Stdlib.__MODULE__)

let dir () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.config_dir xdg) "freetube/devices"

let path_for ~id =
  Stdlib.Filename.concat (dir ()) (Slug.of_friendly_name id ^ ".json")

let load_file path =
  match
    Result.try_with (fun () ->
      Stdio.In_channel.read_all path
      |> Yojson.Safe.from_string
      |> Api.Config_device.of_yojson)
  with
  | Ok (Ok t) -> Some t
  | Ok (Error msg) ->
      Log.warn (fun m -> m "Failed to parse %s: %s — skipping" path msg);
      None
  | Error exn ->
      Log.warn (fun m ->
        m "Failed to read %s: %s — skipping" path (Exn.to_string exn));
      None

type t = Api.Config_device.t list ref

let create () : t =
  let dir = dir () in
  let entries =
    match Stdlib.Sys.file_exists dir with
    | false -> []
    | true ->
        Stdlib.Sys.readdir dir
        |> Array.to_list
        |> List.filter ~f:(fun f -> String.is_suffix f ~suffix:".json")
        |> List.filter_map ~f:(fun f ->
            load_file (Stdlib.Filename.concat dir f))
  in
  ref entries

let all (t : t) = !t

let find (t : t) ~id =
  List.find !t ~f:(fun (d : Api.Config_device.t) ->
    String.equal d.id id)

let static_entries (t : t) =
  List.filter !t ~f:(fun (d : Api.Config_device.t) -> d.is_static)

let save (t : t) (device : Api.Config_device.t) =
  Mkdir_p.ensure (dir ());
  let path = path_for ~id:device.id in
  let tmp = path ^ ".tmp" in
  let data =
    Api.Config_device.to_yojson device |> Yojson.Safe.pretty_to_string
  in
  Stdio.Out_channel.write_all tmp ~data;
  Stdlib.Sys.rename tmp path;
  t := device :: List.filter !t ~f:(fun (d : Api.Config_device.t) ->
    not (String.equal d.id device.id))

let remove (t : t) ~id =
  let path = path_for ~id in
  (match Stdlib.Sys.file_exists path with
   | true -> (try Stdlib.Sys.remove path with _ -> ())
   | false -> ());
  t := List.filter !t ~f:(fun (d : Api.Config_device.t) ->
    not (String.equal d.id id))
