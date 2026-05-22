open! Base
open Util

(** HTTP byte-range probe helpers used by container-aware sources. Errors
    from the HTTP layer are lifted into [Producer.Error.t] at the boundary.

    Sources signal "current probe window is too small, ask for more bytes"
    by raising [Need_more]. Any other exception from the parser is treated
    as a programmer error and propagates. *)

module Log = (val Log_src.src_log ~doc:"byte-range probe" Stdlib.__MODULE__)

exception Need_more

let initial_probe_bytes = 1 lsl 20
let max_probe_bytes = 8 * (1 lsl 20)

let usec_of_ticks ~ticks ~timescale =
  match timescale with
  | 0 -> 0
  | _ -> ticks * 1_000_000 / timescale

let ( let* ) x f = Result.bind x ~f

let rec probe_and_parse ~client ~url ?(headers = []) ~start ~size ~max_size parse =
  match size > max_size with
  | true -> Ok None
  | false ->
      let range =
        Stdlib.Printf.sprintf "bytes=%d-%d" start (start + size - 1)
      in
      let* body, total =
        Http_range.fetch client url ~headers:(("Range", range) :: headers)
          ~start ~len:size ()
        |> Producer.Error.lift_http_range
      in
      match
        try Some (parse body total)
        with
        | Need_more -> None
        | exn ->
            Log.warn (fun m ->
              m "probe parse raised at size=%d: %s" size (Exn.to_string exn));
            None
      with
      | Some _ as ok -> Ok ok
      | None ->
          probe_and_parse ~client ~url ~headers ~start ~size:(size * 2)
            ~max_size parse

let or_parse_error msg = function
  | Ok (Some v) -> Ok v
  | Ok None -> Error (Producer.Error.Parse_error msg)
  | Error _ as e -> e
