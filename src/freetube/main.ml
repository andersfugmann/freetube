open! Base
open Devices

let () =
  Log_config.init ();
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let static_root = Eio.Path.(cwd / "static") in
  let clock = Eio.Stdenv.clock env in
  let global = Freetube.Config_global.load () in
  let device_store = Device_store.create () in
  Eio.Switch.run @@ fun sw ->
  let ntp =
    Airplay_protocol.Ntp_server.start ~sw ~net:(Eio.Stdenv.net env)
      ~clock ~port:global.ntp_port
  in
  Eio.Fiber.all
    [
      (fun () ->
        Discovery_dlna.run ~env ~device_store
          ~interval:global.discovery.dlna_interval_seconds);
      (fun () ->
        Discovery_airplay.run ~env ~device_store
          ~interval:global.discovery.airplay_interval_seconds);
      (fun () ->
        Freetube.Mdns_advertise.run ~sw ~net:(Eio.Stdenv.net env)
          ~port:global.listen_port);
      (fun () ->
        Freetube.Server.start ~env ~port:global.listen_port
          ~static_root ~device_store ~ntp ~sw);
    ]
