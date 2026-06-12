open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA renderer discovery" Stdlib.__MODULE__)

let log_discovered (e : Device.t) =
  match e.client with
  | Dlna c ->
      Log.info (fun m ->
        m "Discovered DLNA renderer: %s (%s)"
          (Dlna.Client.friendly_name c) (Dlna.Client.address c));
      Vendor.log_dlna ~friendly_name:(Dlna.Client.friendly_name c)
        ~manufacturer:(Dlna.Client.manufacturer c)
        ~model_name:(Dlna.Client.model_name c) e.vendor
  | _ -> ()

let log_removed (e : Device.t) =
  match e.client with
  | Dlna c ->
      Log.info (fun m ->
        m "DLNA renderer unavailable: %s (%s)"
          (Dlna.Client.friendly_name c) (Dlna.Client.address c))
  | _ -> ()

let device_of_client (client : Dlna.Client.t) =
  let vendor = Vendor.of_dlna ~manufacturer:(Dlna.Client.manufacturer client) in
  Device.of_dlna ~video_codecs:(Vendor.default_video_codecs vendor)
    ~audio_codecs:(Vendor.default_audio_codecs vendor)
    ~vendor ~stream_format:Dash ~transcode:false
    ~max_width:3840 ~max_height:2160 client

let run ~env ~device_store ~interval =
  let fs = Eio.Stdenv.fs env in
  let discovery =
    Dlna_protocol.Discovery.init ~env ~interval ()
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
         | Dlna _ ->
            Device_store.set_available device_store ~id ~available:false;
            log_removed device
         | _ -> ())
    | _ -> ()
  in
  Dlna_protocol.Discovery.start discovery ~on_added ~on_removed
