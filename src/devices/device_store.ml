open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Per-device config file store" Stdlib.__MODULE__)

let dir () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.config_dir xdg) "freetube/devices"

let path_for ~id =
  Stdlib.Filename.concat (dir ()) (Slug.of_friendly_name id ^ ".json")

let load_file ~fs path =
  let result =
    let ( let* ) result f = Result.bind result ~f in
    let* raw =
      Result.try_with (fun () -> Eio.Path.load Eio.Path.(fs / path))
      |> Result.map_error ~f:(fun exn -> `Read exn)
    in
    let* json =
      Result.try_with (fun () -> Yojson.Safe.from_string raw)
      |> Result.map_error ~f:(fun exn -> `Parse (Exn.to_string exn))
    in
    Device.of_yojson json |> Result.map_error ~f:(fun msg -> `Parse msg)
  in
  match result with
  | Ok t -> Some (t, false)
  | Error (`Parse msg) ->
      Log.warn (fun m -> m "Failed to parse %s: %s — skipping" path msg);
      None
  | Error (`Read exn) ->
      Log.warn (fun m ->
        m "Failed to read %s: %s — skipping" path (Exn.to_string exn));
      None

type entry = Device.discovered
type t = entry list ref

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

let all t = !t

let all_devices t =
  List.map !t ~f:Device.entry_device

let find t ~id =
  List.find_map !t ~f:(fun entry ->
    let (device : Device.t) = Device.entry_device entry in
    match String.equal device.id id with
    | true -> Some device
    | false -> None)

let find_entry t ~id =
  List.find !t ~f:(fun entry ->
    let (device : Device.t) = Device.entry_device entry in
    String.equal device.id id)

let set_available t ~id ~available =
  t :=
    List.map !t ~f:(fun entry ->
      let (device : Device.t) = Device.entry_device entry in
      match String.equal device.id id with
      | true -> device, available
      | false -> entry)

let save ~fs t (device : Device.t) =
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 Eio.Path.(fs / dir ());
  let path = path_for ~id:device.id in
  let tmp = path ^ ".tmp" in
  let data =
    Device.to_yojson device
    |> Yojson.Safe.pretty_to_string
  in
  Eio.Path.save Eio.Path.(fs / tmp) data ~create:(`Or_truncate 0o600);
  Eio.Path.rename Eio.Path.(fs / tmp) Eio.Path.(fs / path);
  let available =
    match find_entry t ~id:device.id with
    | Some entry -> Device.entry_available entry
    | None -> false
  in
  t := (device, available) :: List.filter !t ~f:(fun entry ->
    let (existing : Device.t) = Device.entry_device entry in
    not (String.equal existing.id device.id))

let remove ~fs t ~id =
  let path = path_for ~id in
  (match Eio.Path.is_file Eio.Path.(fs / path) with
   | true ->
       (match Result.try_with (fun () -> Eio.Path.unlink Eio.Path.(fs / path)) with
        | Ok () -> ()
        | Error exn ->
            Log.warn (fun m ->
              m "Failed to remove %s: %s" path (Exn.to_string exn)))
   | false -> ());
  t := List.filter !t ~f:(fun entry ->
    let (device : Device.t) = Device.entry_device entry in
    not (String.equal device.id id))
