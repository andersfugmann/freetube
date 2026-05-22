open! Base
open Util

(* In-flight AirPlay pair-setup registry. The protocol library exposes a
   pure handshake value (`Airplay_protocol.Pairing.t`)  *)

let sessions : (string, Airplay_protocol.Pairing.t) Hashtbl.t =
  Hashtbl.create (module String)

let start ~env ~sw ~address ~port ~receiver_pairing_id =
  let session = Airplay_protocol.Pairing.start ~env ~sw ~address ~port ~receiver_pairing_id in
  let session_id = Uuid.v4 () in
  Hashtbl.set sessions ~key:session_id ~data:session;
  session_id

let submit_pin ~session_id ~pin =
  match Hashtbl.find sessions session_id with
  | None -> Error "unknown session_id"
  | Some session ->
      Hashtbl.remove sessions session_id;
      Ok (Airplay_protocol.Pairing.submit_pin session ~pin)
