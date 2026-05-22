open! Base

(* Recoverable failures surfaced by the public AirPlay API. The caller can
   distinguish a transient transport problem (retryable) from an
   authentication failure (re-pair) from a receiver-side rejection. *)
type t =
  | Network of string
  | Auth_failed of string
  | Command_rejected of { action : string; status : int }
  | Bad_response of string

let to_string = function
  | Network msg -> Printf.sprintf "network error: %s" msg
  | Auth_failed msg -> Printf.sprintf "authentication failed: %s" msg
  | Command_rejected { action; status } ->
      Printf.sprintf "%s rejected by receiver (status %d)" action status
  | Bad_response msg -> Printf.sprintf "unexpected receiver response: %s" msg
