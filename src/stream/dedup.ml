open! Base

(** Dedup functor. Avoid concurrent fetches of the same segment. *)
module Log = (val Util.Log_src.src_log ~doc:"segment dedup" Stdlib.__MODULE__)

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state = {
    inner : M.state;
    pending : (Producer.Segment.t, Exn.t) Result.t Eio.Promise.t Hashtbl.M(Int).t;
  }
  type kind = M.kind
  let witness = M.witness

  let init ~env ~sw ~target =
    let inner, shape = M.init ~env ~sw ~target in
    { inner; pending = Hashtbl.create (module Int) }, shape

  let meta s = M.meta s.inner
  let init_segment s = M.init_segment s.inner
  let segments s = M.segments s.inner
  let max_segment_id s = M.max_segment_id s.inner
  let close s = M.close s.inner

  let fetch_segment s ~id =
    match Hashtbl.find s.pending id with
    | Some waiter ->
      Eio.Promise.await_exn waiter
    | None ->
      let waiter, producer = Eio.Promise.create () in
      Hashtbl.set s.pending ~key:id ~data:waiter;
      try
        let segment = M.fetch_segment s.inner ~id in
        Eio.Promise.resolve_ok producer segment;
        Hashtbl.remove s.pending id;
        segment
      with
      | exn ->
        Eio.Promise.resolve_error producer exn;
        Hashtbl.remove s.pending id;
        raise exn
end
