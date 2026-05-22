open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay NTP timing server" Stdlib.__MODULE__)

type t = { port : int }

let port t = t.port

let respond_once ~clock socket =
  let cstruct = Cstruct.create 128 in
  match Result.try_with (fun () -> Eio.Net.recv socket cstruct) with
  | Error exn ->
      Log.debug (fun m -> m "recv error: %s" (Exn.to_string exn));
      `Continue
  | Ok (peer, n) ->
      match n >= Ntp.Request.packet_size with
      | false -> `Continue
      | true ->
          let req_bytes = Cstruct.to_bytes (Cstruct.sub cstruct 0 n) in
          match Ntp.Request.parse req_bytes with
          | None -> `Continue
          | Some request ->
              let now = Ntp.Ntp_timestamp.now ~clock in
              let response : Ntp.Response.t =
                {
                  proto = request.proto;
                  seq = request.seq;
                  origin = request.origin;
                  receive = now;
                  transmit = now;
                }
              in
              let response_bytes = Ntp.Response.encode response in
              (try
                 Eio.Net.send socket ~dst:peer
                   [ Cstruct.of_bytes response_bytes ]
               with exn ->
                 Log.debug (fun m -> m "send error: %s" (Exn.to_string exn)));
              `Continue

let serve ~clock socket =
  let rec loop () =
    match respond_once ~clock socket with
    | `Continue -> loop ()
  in
  loop ()

let start ~sw ~net ~clock ~port =
  let addr = `Udp (Eio.Net.Ipaddr.V6.any, port) in
  let socket = Eio.Net.datagram_socket ~sw ~reuse_addr:true net addr in
  Log.info (fun m -> m "NTP timing server listening on UDP %d" port);
  Eio.Fiber.fork ~sw (fun () -> serve ~clock socket);
  { port }
