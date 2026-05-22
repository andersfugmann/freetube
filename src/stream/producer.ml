open! Base

module Kind = struct
  type 'k witness =
    | Video : [`Video] witness
    | Audio : [`Audio] witness
    | Muxed : [`Muxed] witness
end

module Container = struct
  (** Raw on-the-wire container reported by a producer. *)
  type kind = Mp4 | Webm | Mpeg_ts

  let to_ext = function
    | Mp4     -> "mp4"
    | Webm    -> "webm"
    | Mpeg_ts -> "ts"

  let string_of_kind = function
    | Mp4     -> "mp4"
    | Webm    -> "webm"
    | Mpeg_ts -> "mpeg_ts"
end

module Shape = struct
  type _ t =
    | Video : { container : Container.kind; codec : Codec.Video.t;
                dynamic_range : Codec.Dynamic_range.t;
                rfc6381 : string } -> [`Video] t
    | Audio : { container : Container.kind; codec : Codec.Audio.t;
                rfc6381 : string } -> [`Audio] t
    | Muxed : { container : Container.kind; video_codec : Codec.Video.t;
                audio_codec : Codec.Audio.t;
                dynamic_range : Codec.Dynamic_range.t } -> [`Muxed] t

  let container (type k) (s : k t) = match s with
    | Video { container; _ } -> container
    | Audio { container; _ } -> container
    | Muxed { container; _ } -> container

  let rfc6381 (type k) (s : k t) = match s with
    | Video { rfc6381; _ } -> rfc6381
    | Audio { rfc6381; _ } -> rfc6381
    | Muxed _ -> ""

  let with_container (type k) (s : k t) c : k t = match s with
    | Video v -> Video { v with container = c }
    | Audio a -> Audio { a with container = c }
    | Muxed m -> Muxed { m with container = c }
end

module Segment_info = struct
  type t = {
    start_usec  : int;
    length_usec : int;
    byte_length : int;
  }
end

module Segments = struct
  type t =
    | Known     of Segment_info.t array
    | Streaming of Segment_info.t array
end

module Segment = struct
  type t = {
    start_usec  : int;
    length_usec : int;
    data        : string;
  }
end

module Meta = struct
  type t = {
    total_duration_usec : int option;
    start_walltime_ms   : int;
    is_live             : bool;
  }
end

module Error = struct
  (** Producer-layer errors. Lower layers (HTTP, container parsers) translate
      their own errors into one of these at the producer boundary. *)
  type t =
    | Source_unavailable of string
    | Parse_error of string
    | Codec_unsupported of string
    | Aborted

  exception E of t

  let to_string = function
    | Source_unavailable s -> Printf.sprintf "source_unavailable: %s" s
    | Parse_error s -> Printf.sprintf "parse_error: %s" s
    | Codec_unsupported s -> Printf.sprintf "codec_unsupported: %s" s
    | Aborted -> "aborted"

  let raise_error t = Stdlib.raise (E t)

  let unwrap = function
    | Ok v -> v
    | Error e -> raise_error e

  let of_http_range : Http_range.Error.t -> t = function
    | Status n      -> Source_unavailable (Printf.sprintf "http %d" n)
    | Bad_range     -> Source_unavailable "range request not honoured"
    | Url_expired   -> Source_unavailable "url expired (http 403)"
    | Network m     -> Source_unavailable (Printf.sprintf "network: %s" m)
    | Timeout       -> Aborted

  let lift_http_range r = Result.map_error r ~f:of_http_range
end

(** One-line summary for leaf-source segment fetches: rendition, segment
    number, size and download speed. *)
let fetch_summary ~kind ~id ~bytes ~elapsed_ms =
  let wallclock = Float.to_int elapsed_ms in
  match Float.(elapsed_ms > 0.0) with
  | true ->
      let mbps = Float.of_int (bytes * 8) /. (elapsed_ms *. 1000.0) in
      Printf.sprintf "%s seg=%d size=%d time=%dms speed=%.1fMbit/s" kind id bytes wallclock mbps
  | false -> Printf.sprintf "%s seg=%d size=%d time=0ms" kind id bytes

let kind_name : type k. k Kind.witness -> string = function
  | Kind.Video -> "video"
  | Kind.Audio -> "audio"
  | Kind.Muxed -> "muxed"

type video = [`Video]
type audio = [`Audio]
type muxed = [`Muxed]

module type S = sig
  type state
  type kind
  val witness        : kind Kind.witness
  val init           : env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> target:kind Shape.t -> state * kind Shape.t
  val meta           : state -> Meta.t
  val init_segment   : state -> string
  val segments       : state -> Segments.t
  val max_segment_id : state -> int
  val fetch_segment  : state -> id:int -> Segment.t
  val close          : state -> unit
end

type _ t =
  | Producer :
      (module S with type state = 's and type kind = 'k) * 's * 'k Shape.t -> 'k t

let init (type k) ~env ~sw ~target (module M : S with type kind = k) : k t =
  let st, sh = M.init ~env ~sw ~target in
  Producer ((module M), st, sh)

let shape (type k) (Producer (_, _, sh) : k t) = sh
let witness (type k) (Producer ((module M), _, _) : k t) : k Kind.witness = M.witness
let meta (type k) (Producer ((module M), s, _) : k t) : Meta.t = M.meta s
let init_segment (type k) (Producer ((module M), s, _) : k t) = M.init_segment s
let segments (type k) (Producer ((module M), s, _) : k t) = M.segments s
let max_segment_id (type k) (Producer ((module M), s, _) : k t) = M.max_segment_id s
let fetch_segment (type k) (Producer ((module M), s, _) : k t) ~id = M.fetch_segment s ~id
let close (type k) (Producer ((module M), s, _) : k t) = M.close s

module type Make = sig
  module Make : (M : S) -> S with type kind = M.kind
end
