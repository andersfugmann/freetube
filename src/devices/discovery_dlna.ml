open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA renderer discovery" Stdlib.__MODULE__)

let now clock = Eio.Time.now clock

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

let device_of_client ~clock (client : Dlna.Client.t) =
  let vendor = Vendor.of_dlna ~manufacturer:(Dlna.Client.manufacturer client) in
  Device.of_dlna ~video_codecs:(Vendor.default_video_codecs vendor)
    ~audio_codecs:(Vendor.default_audio_codecs vendor)
    ~vendor ~stream_format:Dash ~transcode:false
    ~max_width:3840 ~max_height:2160
    ~last_seen:(now clock) client

let scan ~net ~clock ~client ~fs ~device_store =
  let entries =
    Dlna_protocol.Discovery.scan ~net ~clock ~client ()
    |> List.map ~f:(device_of_client ~clock)
  in
  List.iter entries ~f:(fun device ->
    match Device_store.find device_store ~id:device.id with
    | None ->
        Device_store.save ~fs device_store device;
        log_discovered device
    | Some existing ->
        Device_store.save ~fs device_store
          { existing with client = device.client; last_seen = device.last_seen })

let run ~env ~device_store ~interval =
  let net = Eio.Stdenv.net env in
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let client = Http_client.init ~sw ~env () in
  let rec loop () =
    (match Result.try_with (fun () -> scan ~net ~clock ~client ~fs ~device_store) with
     | Ok () -> ()
     | Error exn ->
         Log.err (fun m -> m "Discovery scan failed: %s" (Exn.to_string exn)));
    Eio.Time.sleep clock interval;
    loop ()
  in
  loop ()
