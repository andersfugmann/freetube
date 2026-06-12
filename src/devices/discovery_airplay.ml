open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay device discovery" Stdlib.__MODULE__)

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

let log_removed (e : Device.t) =
  match e.client with
  | Airplay c ->
      Log.info (fun m ->
        m "AirPlay device unavailable: %s (%s:%d)"
          (Airplay.Client.friendly_name c)
          (Airplay.Client.address c) (Airplay.Client.port c))
  | _ -> ()

let device_of_client (client : Airplay.Client.t) =
  let txt = Airplay.Client.txt client in
  let _, vendor = Vendor.of_airplay ~txt ~model:(Airplay.Client.model client) in
  Device.of_airplay ~video_codecs:(Vendor.default_video_codecs vendor)
    ~audio_codecs:(Vendor.default_audio_codecs vendor)
    ~vendor ~stream_format:Hls ~transcode:false
    ~max_width:3840 ~max_height:2160 client

let run ~env ~device_store ~interval =
  let fs = Eio.Stdenv.fs env in
  let discovery =
    Airplay_protocol.Discovery.init ~env ~interval ~timeout:5.0 ()
  in
  let on_added client =
    let device = device_of_client client in
    match Device_store.find device_store ~id:device.id with
    | None ->
        Device_store.save ~fs device_store device;
        Device_store.set_available device_store ~id:device.id ~available:true;
        log_discovered device
    | Some existing ->
        Device_store.save ~fs device_store
         { existing with client = device.client };
        Device_store.set_available device_store ~id:device.id ~available:true
  in
  let on_removed ~id =
    match Device_store.find_entry device_store ~id with
    | Some (device, true) ->
        (match device.client with
         | Airplay _ ->
            Device_store.set_available device_store ~id ~available:false;
            log_removed device
         | _ -> ())
    | _ -> ()
  in
  Airplay_protocol.Discovery.start discovery ~on_added ~on_removed
