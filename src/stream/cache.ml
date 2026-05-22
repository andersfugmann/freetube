open! Base

(** Cache functor — wraps a producer with segment memoisation.
    Caches the last 6 fetched segments in a Linked_queue keyed by
    segment id. *)
module Log = (val Util.Log_src.src_log ~doc:"segment prefetcher" Stdlib.__MODULE__)
let capacity () = (Config.get ()).streaming.cache_capacity

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner : M.state;
    cache : (int * Producer.Segment.t) Linked_queue.t;
  }
  type kind = M.kind
  let witness = M.witness

  let kind = match M.witness with
    | Producer.Kind.Video -> "video"
    | Producer.Kind.Audio -> "audio"
    | Producer.Kind.Muxed -> "muxed"

  let init ~env ~sw ~target =
    let inner, shape = M.init ~env ~sw ~target in
    { inner; cache = Linked_queue.create () }, shape

  let meta s = M.meta s.inner
  let init_segment s = M.init_segment s.inner
  let segments s = M.segments s.inner
  let max_segment_id s = M.max_segment_id s.inner
  let close s = M.close s.inner

  let fetch_segment s ~id =
    match Linked_queue.find s.cache ~f:(fun (id', _) -> id = id') with
    | Some (_, seg) ->
      Log.debug (fun m -> m "Cache hit: %s %d" kind id);
      seg
    | None ->
      Log.debug (fun m -> m "Cache miss: %s %d" kind id);
      let seg = M.fetch_segment s.inner ~id in
      Linked_queue.enqueue s.cache (id, seg);
      while Linked_queue.length s.cache > capacity () do
        Linked_queue.dequeue_and_ignore_exn s.cache
      done;
      seg
end
