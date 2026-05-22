open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HTTP/RTSP message exchange over a HAP-encrypted stream" Stdlib.__MODULE__)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let parse_header_line line =
  match String.lsplit2 line ~on:':' with
  | None -> None
  | Some (name, value) -> Some (String.strip name, String.strip value)

let header_value headers name =
  List.find_map headers ~f:(fun (k, v) ->
    match String.equal (String.lowercase k) (String.lowercase name) with
    | true -> Some v
    | false -> None)

let content_length headers =
  match header_value headers "Content-Length" with
  | None -> 0
  | Some value ->
      match Int.of_string_opt (String.strip value) with
      | Some n -> n
      | None -> 0

let read_status_line line =
  match String.split line ~on:' ' with
  | _ :: code :: _ -> Int.of_string code
  | _ -> Printf.failwithf "malformed status line: %s" line ()

let read_response buf =
  let status_line = Hap_stream.read_line buf in
  let status = read_status_line status_line in
  let rec read_headers acc =
    let line = Hap_stream.read_line buf in
    match String.is_empty line with
    | true -> List.rev acc
    | false ->
        match parse_header_line line with
        | Some pair -> read_headers (pair :: acc)
        | None -> read_headers acc
  in
  let headers = read_headers [] in
  let length = content_length headers in
  let body =
    match length with
    | 0 -> ""
    | n -> Hap_stream.read_exact_plaintext buf n
  in
  { status; headers; body }

let format_headers headers body_length =
  let filtered =
    List.filter headers ~f:(fun (k, _) ->
      not (String.equal (String.lowercase k) "content-length"))
  in
  let all =
    match body_length with
    | 0 -> filtered
    | n -> filtered @ [ "Content-Length", Int.to_string n ]
  in
  List.map all ~f:(fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v)
  |> String.concat

let send_request stream ~request_line ~headers ~body =
  let header_block = format_headers headers (String.length body) in
  let message = request_line ^ "\r\n" ^ header_block ^ "\r\n" ^ body in
  Log.debug (fun m ->
    let headers_str =
      List.map headers ~f:(fun (k, v) -> Printf.sprintf "%s: %s" k v)
      |> String.concat ~sep:" | "
    in
    m "-> %s [body=%d] %s" request_line (String.length body) headers_str);
  Hap_stream.write stream message

let send_and_read stream buf ~request_line ~headers ~body =
  send_request stream ~request_line ~headers ~body;
  read_response buf

(* Reads an inbound RTSP/HTTP request from the peer (used by event channel). *)
let read_request buf =
  let request_line = Hap_stream.read_line buf in
  let rec read_headers acc =
    let line = Hap_stream.read_line buf in
    match String.is_empty line with
    | true -> List.rev acc
    | false ->
        match parse_header_line line with
        | Some pair -> read_headers (pair :: acc)
        | None -> read_headers acc
  in
  let headers = read_headers [] in
  let length = content_length headers in
  let body =
    match length with
    | 0 -> ""
    | n -> Hap_stream.read_exact_plaintext buf n
  in
  request_line, headers, body
