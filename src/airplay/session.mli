module Err := Error
open! Base

(* An established AirPlay 2 URL-playback control session to a receiver. *)
type t

(* Pair-verify against [client] using stored [credentials] and direct the
   receiver's timing to [ntp], then set up the URL-playback streams. *)
val connect :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  client:Airplay.Client.t ->
  credentials:Pairing.credentials ->
  ntp:Ntp_server.t ->
  (t, Err.t) Result.t

val play : t -> content_url:string -> (unit, Err.t) Result.t
val pause : t -> (unit, Err.t) Result.t
val resume : t -> (unit, Err.t) Result.t
val seek : t -> seconds:float -> (unit, Err.t) Result.t
val stop : t -> unit

(* Resolved when the session terminates (event channel EOF or error). *)
val terminated : t -> unit Eio.Promise.t
