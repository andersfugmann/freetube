open! Base

(* A recoverable failure from a DLNA renderer control operation. *)
type t =
  | Network of string
  | Action_failed of { action : string; status : int }

val to_string : t -> string
