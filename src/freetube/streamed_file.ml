open! Base

(** Stream a slice of an on-disk file as a Piaf response body, keeping the
    underlying file descriptor alive on the supplied switch until the body
    stream is drained. The handler builds the response headers from the
    file size; this module only deals with FD ownership and slicing. *)

let chunk_size () = (Config.get ()).network.file_chunk_size

let slice_stream ~file ~offset ~length =
  let remaining = ref length in
  let cursor = ref offset in
  Piaf.Stream.from ~f:(fun () ->
    match !remaining with
    | 0 -> None
    | _ ->
        let want = Int.min (chunk_size ()) !remaining in
        let buf = Bigstringaf.create want in
        let slice = Cstruct.of_bigarray buf ~off:0 ~len:want in
        let n =
          Eio.File.pread file
            ~file_offset:(Optint.Int63.of_int !cursor) [ slice ]
        in
        match n with
        | 0 -> None
        | _ ->
            cursor := !cursor + n;
            remaining := !remaining - n;
            Some (Piaf.IOVec.make buf ~off:0 ~len:n))

let serve ~sw ~path ~build_response =
  let file_promise, file_resolver = Eio.Promise.create () in
  let stream_closed, set_closed = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run @@ fun file_sw ->
    match Eio.Path.open_in ~sw:file_sw path with
    | exception Eio.Io _ ->
        Eio.Promise.resolve file_resolver None
    | file ->
        Eio.Promise.resolve file_resolver (Some file);
        Eio.Promise.await stream_closed);
  match Eio.Promise.await file_promise with
  | None ->
      Eio.Promise.resolve set_closed ();
      `Not_found
  | Some file ->
      let size = Eio.File.size file |> Optint.Int63.to_int in
      let make_body ~offset ~length =
        let stream = slice_stream ~file ~offset ~length in
        Eio.Fiber.fork ~sw (fun () ->
          Piaf.Stream.when_closed stream
            ~f:(fun () -> Eio.Promise.resolve set_closed ()));
        Piaf.Body.of_stream ~length:(`Fixed (Int64.of_int length)) stream
      in
      let release_without_body () = Eio.Promise.resolve set_closed () in
      `Found (build_response ~size ~make_body ~release_without_body)
