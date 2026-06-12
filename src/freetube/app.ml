open! Base
open Devices

type 'env t = {
  env : 'env;
  sw : Eio.Switch.t;
  port : int;
  device_store : Device_store.t;
  global : Config.t;
  sessions : Sessions.t;
  ntp : Airplay_protocol.Ntp_server.t;
}
