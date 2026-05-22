open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Plain HTTP/1.1 over TCP for AirPlay pairing" Stdlib.__MODULE__)

type connection = {
  flow : [ `Generic | `Unix ] Eio.Net.stream_socket_ty Eio.Resource.t;
  buf : Eio.Buf_read.t;
}

let parse_ipv4 address =
  let parts = String.split address ~on:'.' |> List.map ~f:Int.of_string in
  match parts with
  | [ a; b; c; d ] ->
      let bytes = Bytes.create 4 in
      Bytes.set bytes 0 (Char.of_int_exn a);
      Bytes.set bytes 1 (Char.of_int_exn b);
      Bytes.set bytes 2 (Char.of_int_exn c);
      Bytes.set bytes 3 (Char.of_int_exn d);
      Eio.Net.Ipaddr.of_raw (Bytes.to_string bytes)
  | _ -> Printf.failwithf "invalid IPv4 address: %s" address ()

let connect ~net ~sw ~address ~port =
  let host = parse_ipv4 address in
  let addr = `Tcp (host, port) in
  let flow = Eio.Net.connect ~sw net addr in
  let buf = Eio.Buf_read.of_flow flow ~max_size:(1024 * 1024) in
  { flow; buf }

let format_request ~method_ ~path ~headers ~body =
  let header_lines =
    List.map headers ~f:(fun (key, value) -> Printf.sprintf "%s: %s\r\n" key value)
    |> String.concat
  in
  Printf.sprintf "%s %s HTTP/1.1\r\n%sContent-Length: %d\r\n\r\n%s"
    method_ path header_lines (String.length body) body

let read_headers t =
  let rec loop acc =
    let line = Eio.Buf_read.line t.buf in
    match String.is_empty line with
    | true -> List.rev acc
    | false -> loop (line :: acc)
  in
  loop []

let parse_status_line line =
  match String.split line ~on:' ' with
  | _ :: code :: _ -> Int.of_string code
  | _ -> Printf.failwithf "malformed HTTP status line: %s" line ()

let find_content_length headers =
  List.find_map headers ~f:(fun line ->
    match String.lsplit2 line ~on:':' with
    | Some (key, value) when String.equal (String.lowercase (String.strip key)) "content-length" ->
        Some (Int.of_string (String.strip value))
    | _ -> None)
  |> Option.value ~default:0

let post t ~path ~headers ~body =
  let request = format_request ~method_:"POST" ~path ~headers ~body in
  Eio.Flow.copy_string request t.flow;
  let status_line = Eio.Buf_read.line t.buf in
  let status = parse_status_line status_line in
  let header_lines = read_headers t in
  let length = find_content_length header_lines in
  let body = Eio.Buf_read.take length t.buf in
  status, header_lines, body

