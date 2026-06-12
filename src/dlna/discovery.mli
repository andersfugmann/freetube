open! Base

type t

val init :
  env:Eio_unix.Stdenv.base ->
  ?timeout:float ->
  interval:float ->
  unit ->
  t

val start :
  t ->
  on_added:(Dlna.Client.t -> unit) ->
  on_removed:(id:string -> unit) ->
  unit
