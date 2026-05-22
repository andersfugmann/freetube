open! Base

let ensure dir =
  let rec loop dir =
    match Stdlib.Sys.file_exists dir with
    | true -> ()
    | false ->
        loop (Stdlib.Filename.dirname dir);
        (try Stdlib.Sys.mkdir dir 0o700 with Sys_error _ -> ())
  in
  loop dir
