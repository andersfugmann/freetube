module Err := Error
open! Base

(* An active control channel to a DLNA renderer's AVTransport service. *)
type t

val connect :
  env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> client:Dlna.Client.t -> t

val play :
  t ->
  content_url:string ->
  title:string ->
  mime:Mime.t ->
  duration_seconds:float option ->
  resolution:(int * int) option ->
  is_live:bool ->
  (unit, Err.t) Result.t

val pause : t -> (unit, Err.t) Result.t
val resume : t -> (unit, Err.t) Result.t
val seek : t -> seconds:float -> (unit, Err.t) Result.t
val stop : t -> (unit, Err.t) Result.t

(* Resolved when the renderer stops playing (detected via polling). *)
val terminated : t -> unit Eio.Promise.t

(* Poll the renderer's transport. [`Stopped ours] reports whether the renderer's
   current track URI still matches [content_url]. *)
val playback_status :
  t -> content_url:string -> [ `Active | `Stopped of bool | `Unknown ]
