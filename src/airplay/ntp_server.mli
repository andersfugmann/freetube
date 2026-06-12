open! Base

(* AirPlay timing peer: a UDP NTP server the receiver polls to derive its
   playback clock. [init] opens the socket and [start] forks the responder
   onto [sw]. *)
type t

val init :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  port:int ->
  t

val start : t -> unit

val port : t -> int
