open! Base

module Http_client : Http_client.S = Piaf_backend
module Local_ip = Local_ip
module Log_src = Log_src
module Mkdir_p = Mkdir_p
module Uuid = Uuid

let failwith_f fmt =
  Printf.ksprintf failwith fmt
