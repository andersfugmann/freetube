module Err := Error
open! Base


(* An in-flight AirPlay pair-setup handshake. *)
type t

(* Long-term AirPlay pairing credentials, produced by a completed pair-setup
   handshake. Opaque: freetube persists it via the yojson conversions and
   keys storage by [pairing_id]; pair-verify reads the key material through
   the byte accessors. *)
type credentials [@@deriving yojson]

(* The pair-setup handshake yields long-term [credentials]; freetube
   persists them. *)
type outcome = (credentials, Err.t) Result.t

(* Begin pair-setup against [address]:[port]; forks the handshake onto [sw]
   and returns once the receiver has shown its PIN. *)
val start :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  address:string ->
  port:int ->
  receiver_pairing_id:string ->
  t

(* Supply the user-entered PIN and await the resulting credentials. *)
val submit_pin : t -> pin:string -> outcome

val pairing_id : credentials -> string
val controller_pairing_id : credentials -> string
val controller_ltsk : credentials -> string
val receiver_ltpk : credentials -> string

