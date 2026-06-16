open! Base

module Log = (val Util.Log_src.src_log ~doc:"segment prefetcher" Stdlib.__MODULE__)

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner : M.state;
    mutable last_id : int;
    prefetch : Eio.Condition.t;
    count : int;
  }
  type kind = M.kind
  let witness = M.witness

  let kind = match M.witness with
    | Producer.Kind.Video -> "video"
    | Producer.Kind.Audio -> "audio"
    | Producer.Kind.Muxed -> "muxed"

  let prefetch_daemon t : [ `Stop_daemon ] =
    let rec loop ~last_id = function
      | cnt when cnt > t.count || cnt + last_id > M.max_segment_id t.inner ->
        Eio.Condition.await_no_mutex t.prefetch;
        loop ~last_id:t.last_id 1
      | _ when last_id <> t.last_id ->
        loop ~last_id:t.last_id 1
      | cnt ->
        let fetch_ok =
          try
            Log.debug (fun m -> m "Prefetch %s %d" kind (cnt + last_id));
            let (_ : Producer.Segment.t) = M.fetch_segment t.inner ~id:(cnt + last_id) in
            true
          with
          | (Eio.Cancel.Cancelled _ as exn) -> Stdlib.raise exn
          | exn ->
            Log.warn (fun m -> m "Got error on %s %d: %s. sleep" kind (cnt + last_id) (Exn.to_string exn));
            false
        in
        match fetch_ok with
        | true ->
          loop ~last_id (cnt + 1)
        | false ->
          (* Force sleep *)
          loop ~last_id (t.count + 1)
    in
    loop ~last_id:t.last_id 1

  let init ~env ~sw ~target =
    Log.info (fun m -> m "Prefetch initialized");
    let inner, shape = M.init ~env ~sw ~target in
    let count = (Config.get ()).streaming.prefetch_count in

    (* Prefetch at the end of a live stream *)
    let last_id = match (M.info inner).is_live with
      | true -> M.max_segment_id inner - count
      | false -> -1
    in

    let t = { inner; last_id; prefetch = Eio.Condition.create (); count; } in
    Eio.Fiber.fork_daemon ~sw (fun () -> prefetch_daemon t);
    t, shape

  let info t = M.info t.inner
  let init_segment t = M.init_segment t.inner
  let max_segment_id t = M.max_segment_id t.inner
  let close t = M.close t.inner

  let fetch_segment t ~id =
    let segment = M.fetch_segment t.inner ~id in
    t.last_id <- id;
    Eio.Condition.broadcast t.prefetch;
    segment
end
