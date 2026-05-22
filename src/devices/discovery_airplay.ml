open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay device discovery cache" Stdlib.__MODULE__)

type entry = {
  client : Airplay.Client.t;
  video_codecs : Codec.Video.t list;
  audio_codecs : Codec.Audio.t list;
  vendor : Vendor.t; [@default Generic]
  transcode : bool; [@default false]
  stream_format : Api.Stream_format.t; [@default Hls]
  is_static : bool; [@default false]
  last_seen : float;
} [@@deriving yojson { strict = false }]

type stored = { entries : entry list } [@@deriving yojson { strict = false }]

let storage_path () =
  let xdg = Xdg.create ~env:Sys.getenv () in
  Stdlib.Filename.concat (Xdg.data_dir xdg) "freetube/airplay_devices.json"

let load_from_disk () =
  let path = storage_path () in
  match Stdlib.Sys.file_exists path with
  | false -> []
  | true ->
      match
        Result.try_with (fun () -> Stdio.In_channel.read_all path)
        |> Result.map ~f:(fun s -> Yojson.Safe.from_string s |> stored_of_yojson)
      with
      | Ok (Ok s) -> s.entries
      | Ok (Error e) ->
          Log.warn (fun m -> m "Failed to parse %s: %s — deleting" path e);
          (try Stdlib.Sys.remove path with _ -> ());
          []
      | Error exn ->
          Log.warn (fun m -> m "Failed to read %s: %s — deleting" path (Exn.to_string exn));
          (try Stdlib.Sys.remove path with _ -> ());
          []

let save_to_disk entries =
  let persistable = List.filter entries ~f:(fun e -> not e.is_static) in
  let path = storage_path () in
  Mkdir_p.ensure (Stdlib.Filename.dirname path);
  let tmp = path ^ ".tmp" in
  let data = stored_to_yojson { entries = persistable } |> Yojson.Safe.to_string in
  Stdio.Out_channel.write_all tmp ~data;
  Stdlib.Sys.rename tmp path

type t = {
  entries : entry list ref;
  device_store : Device_store.t;
}

let now clock = Eio.Time.now clock

let apply_overrides ~device_store (entry : entry) : entry =
  match Device_store.find device_store ~id:(Airplay.Client.pairing_id entry.client) with
  | None -> entry
  | Some (cfg : Api.Config_device.t) ->
      { entry with
        video_codecs = cfg.video_codecs;
        audio_codecs = cfg.audio_codecs;
        vendor = cfg.vendor;
        transcode = cfg.transcode;
        stream_format = cfg.stream_format;
      }

let static_entry_of_config (cfg : Api.Config_device.t) : entry option =
  match cfg.kind with
  | Some Airplay ->
      let address = Option.value cfg.address ~default:"" in
      let port = Option.value cfg.port ~default:7000 in
      (match
         Result.try_with (fun () ->
           Airplay.Client.create
             ~name:cfg.friendly_name ~fn:cfg.friendly_name
             ~address ~port ~pairing_id:cfg.id ())
       with
       | Error exn ->
           Log.warn (fun m ->
             m "Ignoring static AirPlay device %s: %s"
               cfg.friendly_name (Exn.to_string exn));
           None
       | Ok client ->
           Some {
             client;
             video_codecs = cfg.video_codecs;
             audio_codecs = cfg.audio_codecs;
             vendor = cfg.vendor;
             transcode = cfg.transcode;
             stream_format = cfg.stream_format;
             is_static = true;
             last_seen = Float.infinity;
           })
  | _ -> None

let upsert_entry ~name ~friendly_name existing entry =
  let rec loop = function
    | [] -> [ entry ]
    | current :: _ when current.is_static
                     && String.equal (friendly_name current) (friendly_name entry) ->
        existing
    | current :: rest when String.equal (name current) (name entry) -> entry :: rest
    | current :: rest -> current :: loop rest
  in
  loop existing

let log_discovered prefix (e : entry) =
  let c = e.client in
  Log.info (fun m ->
    m "%s AirPlay device: %s (%s:%d)"
      prefix (Airplay.Client.friendly_name c)
      (Airplay.Client.address c) (Airplay.Client.port c));
  let manufacturer =
    List.Assoc.find (Airplay.Client.txt c) ~equal:String.equal "manufacturer"
  in
  Vendor.log_airplay ~friendly_name:(Airplay.Client.friendly_name c)
    ~manufacturer ~model:(Airplay.Client.model c) e.vendor

let create ~device_store () =
  let live = load_from_disk () in
  let static =
    Device_store.static_entries device_store
    |> List.filter_map ~f:static_entry_of_config
  in
  (* Static entries take precedence over any persisted live row of the
     same friendly_name. *)
  let live =
    List.filter live ~f:(fun e ->
      not (List.exists static ~f:(fun s ->
        String.equal
          (Airplay.Client.friendly_name s.client)
          (Airplay.Client.friendly_name e.client))))
  in
  let entries = static @ live in
  List.iter entries ~f:(log_discovered "Loaded");
  { entries = ref entries; device_store }

let active cache = !(cache.entries)

let to_device (e : entry) : Device.t =
  Device.of_airplay ~video_codecs:e.video_codecs ~audio_codecs:e.audio_codecs
    ~vendor:e.vendor ~transcode:e.transcode ~stream_format:e.stream_format
    ~last_seen:e.last_seen e.client

let list cache = active cache |> List.map ~f:to_device

let find cache ~friendly_name =
  active cache
  |> List.find ~f:(fun entry ->
       String.equal (Airplay.Client.friendly_name entry.client) friendly_name)
  |> Option.map ~f:to_device

let merge cache entries =
  let name e = Airplay.Client.name e.client in
  let friendly_name e = Airplay.Client.friendly_name e.client in
  let entries =
    List.map entries ~f:(apply_overrides ~device_store:cache.device_store)
  in
  let existing = !(cache.entries) in
  List.iter entries ~f:(fun e ->
    match List.exists existing ~f:(fun c -> String.equal (name c) (name e)) with
    | true -> ()
    | false -> log_discovered "Discovered" e);
  let updated =
    List.fold entries ~init:existing ~f:(upsert_entry ~name ~friendly_name)
  in
  cache.entries := updated;
  match Result.try_with (fun () -> save_to_disk updated) with
  | Ok () -> ()
  | Error exn ->
      Log.warn (fun m -> m "Failed to persist airplay devices: %s" (Exn.to_string exn))

let entry_of_device ~clock (client : Airplay.Client.t) =
  let txt = Airplay.Client.txt client in
  let _, vendor = Vendor.of_airplay ~txt ~model:(Airplay.Client.model client) in
  {
    client;
    video_codecs = Vendor.default_video_codecs vendor;
    audio_codecs = Vendor.default_audio_codecs vendor;
    vendor;
    stream_format = Api.Stream_format.Hls;
    transcode = false;
    is_static = false;
    last_seen = now clock;
  }

let scan ~env ~cache =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let devices = Airplay_protocol.Discovery.scan ~net ~clock ~timeout:5.0 () in
  let entries = List.map devices ~f:(entry_of_device ~clock) in
  merge cache entries

let run ~env ~cache ~interval =
  let clock = Eio.Stdenv.clock env in
  let rec loop () =
    (match Result.try_with (fun () -> scan ~env ~cache) with
     | Ok () -> ()
     | Error exn ->
         Log.err (fun m -> m "AirPlay discovery scan failed: %s" (Exn.to_string exn)));
    Eio.Time.sleep clock interval;
    loop ()
  in
  loop ()

