open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Per-device config file store" Stdlib.__MODULE__)

let dir () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.config_dir xdg) "freetube/devices"

let path_for ~id =
  Stdlib.Filename.concat (dir ()) (Slug.of_friendly_name id ^ ".json")

let load_file ~fs path =
  match
    Result.try_with (fun () ->
      Eio.Path.load Eio.Path.(fs / path)
      |> Yojson.Safe.from_string
      |> Device.of_yojson)
  with
  | Ok (Ok t) -> Some t
  | Ok (Error msg) ->
      Log.warn (fun m -> m "Failed to parse %s: %s — skipping" path msg);
      None
  | Error exn ->
      Log.warn (fun m ->
        m "Failed to read %s: %s — skipping" path (Exn.to_string exn));
      None

type t = Device.t list ref

let create ~fs () : t =
  let dir = dir () in
  let entries =
    match Eio.Path.is_directory Eio.Path.(fs / dir) with
    | false -> []
    | true ->
        Eio.Path.read_dir Eio.Path.(fs / dir)
        |> List.filter ~f:(fun f -> String.is_suffix f ~suffix:".json")
        |> List.filter_map ~f:(fun f ->
            load_file ~fs (Stdlib.Filename.concat dir f))
  in
  ref entries

let all (t : t) = !t

let find (t : t) ~id =
  List.find !t ~f:(fun (d : Device.t) ->
    String.equal d.id id)


let save ~fs (t : t) (device : Device.t) =
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 Eio.Path.(fs / dir ());
  let path = path_for ~id:device.id in
  let tmp = path ^ ".tmp" in
  let data =
    Device.to_yojson device |> Yojson.Safe.pretty_to_string
  in
  Eio.Path.save Eio.Path.(fs / tmp) data ~create:(`Or_truncate 0o600);
  Eio.Path.rename Eio.Path.(fs / tmp) Eio.Path.(fs / path);
  t := device :: List.filter !t ~f:(fun (d : Device.t) ->
    not (String.equal d.id device.id))

let remove ~fs (t : t) ~id =
  let path = path_for ~id in
  (match Eio.Path.is_file Eio.Path.(fs / path) with
   | true -> (try Eio.Path.unlink Eio.Path.(fs / path) with _ -> ())
   | false -> ());
  t := List.filter !t ~f:(fun (d : Device.t) ->
    not (String.equal d.id id))
