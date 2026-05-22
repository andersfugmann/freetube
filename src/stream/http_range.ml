open! Base
open Util

module Error = struct
  type t =
    | Status of int
    | Bad_range
    | Url_expired
    | Network of string
    | Timeout
end

module Log = (val Log_src.src_log ~doc:"HTTP byte-range fetch" Stdlib.__MODULE__)

let parse_content_range_total v =
  match String.split v ~on:'/' with
  | [ _; total_s ] ->
      (match String.strip total_s with
       | "*" -> None
       | s -> Int.of_string_opt s)
  | _ -> None

let map_status ~start ~len:_ ~body ~headers status
  : (string * int, Error.t) Result.t =
  let total_from_cr () =
    match List.find_map headers ~f:(fun (k, v) ->
        match String.equal (String.lowercase k) "content-range" with
        | true -> Some v
        | false -> None)
    with
    | Some v -> parse_content_range_total v
    | None -> None
  in
  match status, start with
  | 206, _ ->
      let total =
        match total_from_cr () with
        | Some t -> t
        | None -> start + String.length body
      in
      Ok (body, total)
  | 200, 0 ->
      Ok (body, String.length body)
  | 200, _ -> Error Error.Bad_range
  | 403, _ ->
      Log.warn (fun m -> m "range response: 403 Forbidden (URL expired?)");
      Error Error.Url_expired
  | (code, _) when code >= 400 ->
      Log.warn (fun m -> m "range response: %d" code);
      Error (Error.Status code)
  | code, _ ->
      Log.warn (fun m -> m "range response: unexpected %d" code);
      Error (Error.Status code)

let head client url ?(headers = []) ()
  : (int, Error.t) Result.t =
  let uri = Uri.of_string url in
  Log.debug (fun m ->
    m "head %s headers=[%s]" url
      (List.map headers ~f:fst |> String.concat ~sep:";"));
  let total_from headers =
    List.find_map headers ~f:(fun (k, v) ->
      match String.equal (String.lowercase k) "content-length" with
      | true -> Int.of_string_opt (String.strip v)
      | false -> None)
  in
  try
    let response = Http_client.head client ~ip_version:`V6 ~headers uri in
    Log.debug (fun m -> m "head %s: %d" url response.status);
    match response.status with
    | 200 ->
        (match total_from response.headers with
         | Some n -> Ok n
         | None -> Error (Error.Status 200))
    | 403 ->
        Error Error.Url_expired
    | code when code >= 400 ->
        Error (Error.Status code)
    | code ->
        Error (Error.Status code)
  with
  | Http_client.Http_failure m -> Error (Error.Network m)
  | Eio.Time.Timeout -> Error Error.Timeout
  | End_of_file ->
      Log.err (fun m -> m "head %s: unexpected end-of-file" url);
      Error (Error.Network "end-of-file")
  | exn ->
      Log.err (fun m -> m "head %s: %s" url (Exn.to_string exn));
      Error (Error.Network (Exn.to_string exn))

let fetch client url ?(headers = []) ~start ~len ()
  : (string * int, Error.t) Result.t =
  let range_value =
    Stdlib.Printf.sprintf "bytes=%d-%d" start (start + len - 1)
  in
  let uri = Uri.of_string url in
  Log.debug (fun m ->
    m "fetch %s %s headers=[%s]" url range_value
      (List.map headers ~f:fst |> String.concat ~sep:";"));
  try
    let response = Http_client.get client ~ip_version:`V6 ~headers uri in
    map_status
      ~start ~len
      ~body:response.body
      ~headers:response.headers
      response.status
  with
  | Http_client.Http_failure m -> Error (Error.Network m)
  | Eio.Time.Timeout -> Error Error.Timeout
  | End_of_file ->
      Log.err (fun m -> m "fetch %s %s: unexpected end-of-file" url range_value);
      Error (Error.Network "end-of-file")
  | exn ->
      Log.err (fun m -> m "fetch %s %s: %s" url range_value (Exn.to_string exn));
      Error (Error.Network (Exn.to_string exn))
