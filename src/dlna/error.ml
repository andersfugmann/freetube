open! Base

(* A recoverable failure from a DLNA renderer control operation. *)
type t =
  | Network of string
  | Action_failed of { action : string; status : int }

let to_string = function
  | Network msg -> Printf.sprintf "DLNA network error: %s" msg
  | Action_failed { action; status } ->
      Printf.sprintf "DLNA %s failed (HTTP %d)" action status
