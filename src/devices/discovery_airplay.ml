open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay device discovery" Stdlib.__MODULE__)

let now clock = Eio.Time.now clock

let log_discovered (e : Device.t) =
  match e.client with
  | Airplay c ->
      Log.info (fun m ->
        m "Discovered AirPlay device: %s (%s:%d)"
          (Airplay.Client.friendly_name c)
          (Airplay.Client.address c) (Airplay.Client.port c));
      let manufacturer =
        List.Assoc.find (Airplay.Client.txt c) ~equal:String.equal "manufacturer"
      in
      Vendor.log_airplay ~friendly_name:(Airplay.Client.friendly_name c)
        ~manufacturer ~model:(Airplay.Client.model c) e.vendor
  | _ -> ()

let device_of_client ~clock (client : Airplay.Client.t) =
  let txt = Airplay.Client.txt client in
  let _, vendor = Vendor.of_airplay ~txt ~model:(Airplay.Client.model client) in
  Device.of_airplay ~video_codecs:(Vendor.default_video_codecs vendor)
    ~audio_codecs:(Vendor.default_audio_codecs vendor)
    ~vendor ~stream_format:Hls ~transcode:false
    ~max_width:3840 ~max_height:2160
    ~last_seen:(now clock) client

let scan ~env ~device_store =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let clients = Airplay_protocol.Discovery.scan ~net ~clock ~timeout:5.0 () in
  List.iter clients ~f:(fun client ->
    let device = device_of_client ~clock client in
    match Device_store.find device_store ~id:device.id with
    | None ->
        Device_store.save device_store device;
        log_discovered device
    | Some existing ->
        Device_store.save device_store
          { existing with client = device.client; last_seen = device.last_seen })

let run ~env ~device_store ~interval =
  let clock = Eio.Stdenv.clock env in
  let rec loop () =
    (match Result.try_with (fun () -> scan ~env ~device_store) with
     | Ok () -> ()
     | Error exn ->
         Log.err (fun m -> m "AirPlay discovery scan failed: %s" (Exn.to_string exn)));
    Eio.Time.sleep clock interval;
    loop ()
  in
  loop ()

