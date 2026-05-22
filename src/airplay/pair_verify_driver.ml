open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Drives HAP pair-verify over plain HTTP, then hands off to HAP transport" Stdlib.__MODULE__)

let pair_verify_user_agent = "AirPlay/870.14.1"

let verify_headers =
  [
    "User-Agent", pair_verify_user_agent;
    "X-Apple-HKP", "3";
    "Content-Type", "application/octet-stream";
    "Connection", "keep-alive";
  ]

let check_ok status path =
  match status with
  | 200 -> ()
  | code -> Printf.failwithf "%s returned HTTP %d" path code ()

let post_or_fail t ~path ~body =
  let status, _headers, response = Http_tcp.post t ~path ~headers:verify_headers ~body in
  check_ok status path;
  response

let result_or_fail context = function
  | Ok value -> value
  | Error message -> Printf.failwithf "%s: %s" context message ()

let run ~net ~sw ~address ~port ~(credentials : Pairing.credentials) =
  Log.info (fun m -> m "pair-verify against %s:%d" address port);
  let t = Http_tcp.connect ~net ~sw ~address ~port in
  let ephemeral_private, m1 = Pair_verify.build_m1 () in
  let m2 = post_or_fail t ~path:"/pair-verify" ~body:m1 in
  let session_keys, m3 =
    result_or_fail "process_m2" (Pair_verify.process_m2 ~credentials ~ephemeral_private m2)
  in
  let m4 = post_or_fail t ~path:"/pair-verify" ~body:m3 in
  result_or_fail "verify_m4" (Pair_verify.verify_m4 m4);
  Log.info (fun m -> m "pair-verify complete; switching to HAP transport");
  let stream = Hap_stream.create ~session_keys ~flow:t.flow in
  stream, session_keys
