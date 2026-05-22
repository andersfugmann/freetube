open! Base

(* Browse the LAN for DLNA MediaRenderers via SSDP, fetching and parsing each
   device description into a [Dlna.Client.t]. [client] is an HTTP client used for
   the description fetch. *)
val scan :
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  client:Util.Http_client.t ->
  ?timeout:float ->
  unit ->
  Dlna.Client.t list
