open! Base

(* AirPlay timing peer: a UDP NTP server the receiver polls to derive its
   playback clock. [start] forks the responder onto [sw]. *)
type t

val start :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  port:int ->
  t

val port : t -> int
