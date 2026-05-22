open! Base

type t =
  | Network of string
  | Auth_failed of string
  | Command_rejected of { action : string; status : int }
  | Bad_response of string

val to_string : t -> string
