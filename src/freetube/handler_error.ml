open! Base

type t =
  [ `Not_found
  | `Bad_param of string
  | `Conflict of string
  | `Unauthorized of string
  | `Upstream_error of string
  | `Internal_error of string
  | `Range_not_satisfiable of int
  ]

let message = function
  | `Not_found -> "Not Found"
  | `Bad_param msg -> msg
  | `Conflict msg -> msg
  | `Unauthorized msg -> msg
  | `Upstream_error msg -> msg
  | `Internal_error msg -> msg
  | `Range_not_satisfiable _ -> ""

