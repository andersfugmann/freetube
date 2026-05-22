open! Base

(** Prefetch functor — on every fetch_segment ~id, spawns a fiber
    to fetch id+1 through the inner producer (warming the cache)
    without blocking the caller. *)
module Log = (val Util.Log_src.src_log ~doc:"segment prefetcher" Stdlib.__MODULE__)

let prefetch_count () = (Config.get ()).streaming.prefetch_count

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner : M.state;
    mutable last_id : int;
    prefetch : Eio.Condition.t;
  }
  type kind = M.kind
  let witness = M.witness

  let kind = match M.witness with
    | Producer.Kind.Video -> "video"
    | Producer.Kind.Audio -> "audio"
    | Producer.Kind.Muxed -> "muxed"

  let rec prefetch_daemon t : [ `Stop_daemon ] =
    let rec loop ~last_id cnt =
      let id = last_id + cnt in
      Log.debug (fun m -> m "Prefetch %s %d" kind id);
      match M.fetch_segment t.inner ~id with
      | _ when last_id = t.last_id |> not ->
        loop ~last_id:t.last_id 1
      | _ when cnt < prefetch_count () && id <= M.max_segment_id t.inner ->
        loop ~last_id (cnt + 1)
      | _ -> ()
      | exception (Eio.Cancel.Cancelled _ as exn) ->
        Stdlib.raise exn
      | exception exn ->
        Log.debug (fun m -> m "Got error on %s %d: %s. sleep" kind id (Exn.to_string exn));
    in
    loop ~last_id:t.last_id 1;
    Eio.Condition.await_no_mutex t.prefetch;
    prefetch_daemon t

  let init ~env ~sw ~target =
    Log.info (fun m -> m "Prefetch initialized");
    let inner, shape = M.init ~env ~sw ~target in
    let t = { inner; last_id = -1; prefetch = Eio.Condition.create () } in
    Eio.Fiber.fork_daemon ~sw (fun () -> prefetch_daemon t);
    t, shape

  let meta t = M.meta t.inner
  let init_segment t = M.init_segment t.inner
  let segments t = M.segments t.inner
  let max_segment_id t = M.max_segment_id t.inner
  let close t = M.close t.inner

  let fetch_segment t ~id =
    let segment = M.fetch_segment t.inner ~id in
    t.last_id <- id;
    Eio.Condition.broadcast t.prefetch;
    segment
end
