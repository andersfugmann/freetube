open! Base

module Log = (val Util.Log_src.src_log ~doc:"Life segment backoff" Stdlib.__MODULE__)

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner : M.state;
    mutable info: Producer.Info.t;
    mutable max_segment_id: int;
  }

  type kind = M.kind
  let witness = M.witness

  let kind = match M.witness with
    | Producer.Kind.Video -> "video"
    | Producer.Kind.Audio -> "audio"
    | Producer.Kind.Muxed -> "muxed"

  let update t =
    t.info <- M.info t.inner;
    t.max_segment_id <- M.max_segment_id t.inner;
    ()

  let rec live_backoff t length_usec =
    Eio_unix.sleep (Float.of_int length_usec /. 1_000_000. +. 1.);
    let prev_max_segment_id = t.max_segment_id in
    update t;
    Log.info (fun m -> m "Move forward %s segment_id: %d -> %d" kind prev_max_segment_id t.max_segment_id);
    live_backoff t length_usec

  let init ~env ~sw ~target =
    Log.info (fun m -> m "live backoff initialized");
    let inner, shape = M.init ~env ~sw ~target in
    let info = M.info inner in
    let max_segment_id = M.max_segment_id inner in
    (* Could crash, if there are no segments yet *)
    let length_usec = info.segments.(0).length_usec in

    let t = { inner; info; max_segment_id } in
    Eio.Fiber.fork_daemon ~sw (fun () -> live_backoff t length_usec);
    t, shape

  let info t = t.info
  let init_segment t = M.init_segment t.inner
  let max_segment_id t = t.max_segment_id
  let close t = M.close t.inner
  let fetch_segment t ~id = M.fetch_segment t.inner ~id
end
