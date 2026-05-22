open! Base
open Util

module Log = (val Log_src.src_log ~doc:"storyboard sprite cache" Stdlib.__MODULE__)

type t = {
  fragments : Youtube.Video_info.Storyboard.fragment array;
  columns : int;
  rows : int;
  thumb_width : int;
  thumb_height : int;
  client : Http_client.t;
  sw : Eio.Switch.t;
  cache : (int, string Eio.Promise.or_exn) Hashtbl.t;
  mutable prefetch_started : bool;
}

let fetch_one client url =
  let uri = Uri.of_string url in
  let resp = Http_client.get client ~ip_version:`V6 uri in
  resp.body

let start_prefetch t =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
    Array.iteri t.fragments ~f:(fun i frag ->
      match Hashtbl.mem t.cache i with
      | true -> ()
      | false ->
        let p, resolver = Eio.Promise.create () in
        Hashtbl.set t.cache ~key:i ~data:p;
        match fetch_one t.client frag.url with
        | data ->
          Eio.Promise.resolve_ok resolver data;
          Log.debug (fun m -> m "prefetched storyboard %d/%d" (i + 1) (Array.length t.fragments))
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn ->
          Eio.Promise.resolve_error resolver exn;
          Log.warn (fun m -> m "storyboard prefetch %d failed: %s" i (Exn.to_string exn)));
    `Stop_daemon)

let init ~sw ~client ~(storyboard : Youtube.Video_info.Storyboard.t) =
  { fragments = Array.of_list storyboard.fragments;
    columns = storyboard.columns;
    rows = storyboard.rows;
    thumb_width = storyboard.width;
    thumb_height = storyboard.height;
    client;
    sw;
    cache = Hashtbl.create (module Int);
    prefetch_started = false }

let fetch t ~id =
  (match t.prefetch_started with
   | true -> ()
   | false ->
     t.prefetch_started <- true;
     start_prefetch t);
  match Hashtbl.find t.cache id with
  | Some p -> Eio.Promise.await_exn p
  | None ->
    let p, resolver = Eio.Promise.create () in
    Hashtbl.set t.cache ~key:id ~data:p;
    let data = fetch_one t.client t.fragments.(id).url in
    Eio.Promise.resolve_ok resolver data;
    data

let count t = Array.length t.fragments
let columns t = t.columns
let rows t = t.rows
let thumb_width t = t.thumb_width
let thumb_height t = t.thumb_height
let fragment_duration t ~id = t.fragments.(id).duration
