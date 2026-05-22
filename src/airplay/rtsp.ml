open! Base
open Util

module Log = (val Log_src.src_log ~doc:"RTSP request and response codec" Stdlib.__MODULE__)

type request = {
  method_ : string;
  path : string;
  headers : (string * string) list;
  body : string;
}

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let normalize_target path =
  match String.is_prefix path ~prefix:"rtsp://" with
  | true -> path
  | false -> "rtsp://localhost" ^ path

let build_request ~cseq (request : request) =
  let headers =
    request.headers
    |> List.filter ~f:(fun (name, _value) ->
      not (String.equal name "CSeq" || String.equal name "Content-Length"))
    |> List.append [ "CSeq", Int.to_string cseq ]
    |> List.append [ "Content-Length", Int.to_string (String.length request.body) ]
  in
  let header_block =
    headers
    |> List.map ~f:(fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
    |> String.concat
  in
  request.method_
  ^ " "
  ^ normalize_target request.path
  ^ " RTSP/1.0\r\n"
  ^ header_block
  ^ "\r\n"
  ^ request.body

let lines_of_headers headers =
  headers
  |> String.split ~on:'\n'
  |> List.map ~f:(String.strip ~drop:(Char.equal '\r'))

let parse_header line =
  match String.lsplit2 line ~on:':' with
  | None -> None
  | Some (name, value) -> Some (name, String.strip value)

let parse_response value =
  match String.substr_index value ~pattern:"\r\n\r\n" with
  | None -> None
  | Some separator_index ->
      let header_block = String.prefix value separator_index in
      let body = String.drop_prefix value (separator_index + 4) in
      (match lines_of_headers header_block with
       | [] -> None
       | status_line :: header_lines ->
           (match String.split status_line ~on:' ' with
            | _protocol :: status :: _reason ->
                (try
                   Some
                     {
                       status = Int.of_string status;
                       headers = List.filter_map header_lines ~f:parse_header;
                       body;
                     }
                 with
                 | _ -> None)
            | _ -> None))

let%test "build_request adds cseq and length" =
  let request =
    { method_ = "POST"; path = "/play"; headers = [ "Content-Type", "text/plain" ]; body = "ok" }
  in
  let encoded = build_request ~cseq:7 request in
  String.is_substring encoded ~substring:"CSeq: 7\r\n"
  && String.is_substring encoded ~substring:"Content-Length: 2\r\n"
  && String.is_substring encoded ~substring:"rtsp://localhost/play"

let%test "parse_response reads status headers and body" =
  let raw =
    "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 5\r\n\r\nhello"
  in
  match parse_response raw with
  | None -> false
  | Some response ->
      Int.equal response.status 200
      && Poly.equal response.body "hello"
      && Poly.equal response.headers [ "CSeq", "1"; "Content-Length", "5" ]
