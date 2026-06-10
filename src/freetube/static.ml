open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Static file server" Stdlib.__MODULE__)

let content_type_of_ext = function
  | ".html" -> "text/html"
  | ".css" -> "text/css"
  | ".js" -> "application/javascript"
  | ".json" -> "application/json"
  | ".png" -> "image/png"
  | ".jpg" | ".jpeg" -> "image/jpeg"
  | ".gif" -> "image/gif"
  | ".svg" -> "image/svg+xml"
  | ".ico" -> "image/x-icon"
  | ".woff2" -> "font/woff2"
  | ".mp4" | ".m4v" | ".m4s" | ".cmfv" -> "video/mp4"
  | ".m4a" | ".cmfa" -> "audio/mp4"
  | ".webm" -> "video/webm"
  | ".m3u8" -> "application/vnd.apple.mpegurl"
  | ".mpd" -> "application/dash+xml"
  | ".ts" -> "video/mp2t"
  | ".aac" -> "audio/aac"
  | ".mp3" -> "audio/mpeg"
  | ".opus" -> "audio/opus"
  | ".flac" -> "audio/flac"
  | ".wav" -> "audio/wav"
  | ".vtt" -> "text/vtt"
  | ".srt" -> "application/x-subrip"
  | ".key" -> "application/octet-stream"
  | _ -> "application/octet-stream"

let resolve_path ~root path =
  let normalized =
    path
    |> String.split ~on:'/'
    |> List.filter ~f:(fun s -> not (String.is_empty s || String.equal s ".."))
    |> String.concat ~sep:"/"
  in
  Eio.Path.(root / normalized)

type range = { start : int; length : int }

let parse_range header ~total =
  let ( let* ) o f = Option.bind o ~f in
  let* spec = String.chop_prefix header ~prefix:"bytes=" in
  let first = String.split spec ~on:',' |> List.hd_exn |> String.strip in
  match String.split first ~on:'-' with
  | [ start_s; end_s ] ->
      let start_o = Stdlib.int_of_string_opt (String.strip start_s) in
      let end_o = Stdlib.int_of_string_opt (String.strip end_s) in
      (match start_o, end_o with
       | None, Some suffix when suffix > 0 ->
           let length = Int.min suffix total in
           Some { start = total - length; length }
       | Some start, None when start < total ->
           Some { start; length = total - start }
       | Some start, Some last when start < total && start <= last ->
           let last = Int.min last (total - 1) in
           Some { start; length = last - start + 1 }
       | _ -> None)
  | _ -> None

let respond_not_found () =
  Piaf.Response.of_string ~body:"Not Found" `Not_found

let respond_range_not_satisfiable ~total =
  let headers =
    Piaf.Headers.of_list
      [ "content-range", Printf.sprintf "bytes */%d" total ]
  in
  Piaf.Response.of_string ~headers ~body:"" `Range_not_satisfiable

let response_headers ~content_type ~length ~range ~total =
  let base =
    [
      "content-type", content_type;
      "accept-ranges", "bytes";
      "content-length", Int.to_string length;
    ]
  in
  let extra =
    match range with
    | None -> []
    | Some { start; length } ->
        [
          "content-range",
          Printf.sprintf "bytes %d-%d/%d" start (start + length - 1) total;
        ]
  in
  Piaf.Headers.of_list (base @ extra)

let serve ~sw ~root (request : Piaf.Request.t) =
  let uri = Piaf.Request.uri request in
  let path = Uri.path uri in
  let meth = Piaf.Request.meth request in
  match String.chop_prefix ~prefix:"/static/" path with
  | None -> respond_not_found ()
  | Some relative_path ->
      let file_path = resolve_path ~root relative_path in
      let build_response ~size ~make_body ~release_without_body =
        let total = size in
        let ext = Stdlib.Filename.extension relative_path in
        let content_type = content_type_of_ext ext in
        let range_header =
          Piaf.Headers.get (Piaf.Request.headers request) "range"
        in
        let parsed_range =
          range_header |> Option.bind ~f:(fun header -> parse_range header ~total)
        in
        match range_header, parsed_range with
        | Some _, None when total > 0 ->
            release_without_body ();
            respond_range_not_satisfiable ~total
        | _, _ ->
            let range = parsed_range in
            let status, offset, length =
              match range with
              | None -> `OK, 0, total
              | Some r -> `Partial_content, r.start, r.length
            in
            let headers = response_headers ~content_type ~length ~range ~total in
            match meth with
            | `HEAD ->
                release_without_body ();
                Piaf.Response.create ~headers status
            | _ ->
                let body = make_body ~offset ~length in
                Piaf.Response.create ~headers ~body status
      in
      match Streamed_file.serve ~sw ~path:file_path ~build_response with
      | `Not_found ->
          Log.debug (fun m -> m "File not found: %s" relative_path);
          respond_not_found ()
      | `Found response -> response

let%test "parse_range handles open-ended start" =
  match parse_range "bytes=500-" ~total:1000 with
  | Some { start = 500; length = 500 } -> true
  | _ -> false

let%test "parse_range handles closed range" =
  match parse_range "bytes=0-499" ~total:1000 with
  | Some { start = 0; length = 500 } -> true
  | _ -> false

let%test "parse_range handles suffix" =
  match parse_range "bytes=-200" ~total:1000 with
  | Some { start = 800; length = 200 } -> true
  | _ -> false

let%test "parse_range rejects out-of-bounds" =
  match parse_range "bytes=2000-3000" ~total:1000 with
  | None -> true
  | _ -> false
