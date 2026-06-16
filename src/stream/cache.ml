open! Base

(** Cache functor — wraps a producer with segment memoisation.
    Keeps the [streaming.cache_capacity] most-recently-accessed segments
    in an LRU keyed by segment id. *)
module Log = (val Util.Log_src.src_log ~doc:"segment prefetcher" Stdlib.__MODULE__)

module Cache_entry = struct
  type t = Producer.Segment.t
  let weight _ = 1
end
module Lru_cache = Lru.M.Make (Int)(Cache_entry)

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner : M.state;
    cache : Lru_cache.t;
  }
  type kind = M.kind
  let witness = M.witness

  let kind = match M.witness with
    | Producer.Kind.Video -> "video"
    | Producer.Kind.Audio -> "audio"
    | Producer.Kind.Muxed -> "muxed"

  let init ~env ~sw ~target =
    let inner, shape = M.init ~env ~sw ~target in
    { inner; cache = Lru_cache.create (Config.get ()).streaming.cache_capacity }, shape

  let info s = M.info s.inner
  let init_segment s = M.init_segment s.inner
  let max_segment_id s = M.max_segment_id s.inner
  let close s = M.close s.inner

  let fetch_segment s ~id =
    match Lru_cache.find id s.cache with
    | Some seg ->
      Lru_cache.promote id s.cache;
      Log.debug (fun m -> m "Cache hit: %s %d" kind id);
      seg
    | None ->
      Log.debug (fun m -> m "Cache miss: %s %d" kind id);
      let seg = M.fetch_segment s.inner ~id in
      Lru_cache.add id seg s.cache;
      Lru_cache.trim s.cache;
      seg
end
