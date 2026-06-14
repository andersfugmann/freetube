open! Base

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type ip_version = [ `V4 | `V6 ]

module type S = sig
  type t
  type nonrec response = response
  exception Http_failure of string
  val init: max_conn_per_host:int -> sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit -> t
  val close : t -> unit
  val head : t -> ip_version:ip_version -> ?headers:(string * string) list -> ?oneshot:bool -> Uri.t -> response
  val get : t -> ip_version:ip_version -> ?headers:(string * string) list -> ?oneshot:bool -> Uri.t -> response
  val post : t -> ip_version:ip_version -> ?headers:(string * string) list -> ?content_type:string -> ?oneshot:Export.bool -> body:string -> Uri.t -> response
end
