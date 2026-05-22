open! Base
open Devices

type ('env, 'root) t = {
  env : 'env;
  sw : Eio.Switch.t;
  port : int;
  static_root : 'root;
  dlna_cache : Discovery_dlna.t;
  airplay_cache : Discovery_airplay.t;
  device_store : Device_store.t;
  global : Config.t;
  sessions : Sessions.t;
  ntp : Airplay_protocol.Ntp_server.t;
}
