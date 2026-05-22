open! Base
open Util

module Log = (val Log_src.src_log ~doc:"mDNS service advertisement" Stdlib.__MODULE__)

let multicast_addr = "224.0.0.251"
let mdns_port = 5353
let hostname = "freetube.local"

let encode_name name =
  let labels =
    String.split name ~on:'.' |> List.filter ~f:(Fn.non String.is_empty)
  in
  let buf = Buffer.create 64 in
  List.iter labels ~f:(fun label ->
    Buffer.add_char buf (Char.of_int_exn (String.length label));
    Buffer.add_string buf label);
  Buffer.add_char buf '\000';
  Buffer.contents buf

let u16_at s offset =
  (Char.to_int s.[offset] lsl 8) lor Char.to_int s.[offset + 1]

let rec read_name payload offset acc depth =
  match depth > 32 with
  | true -> None
  | false ->
      match offset >= String.length payload with
      | true -> None
      | false ->
          let len = Char.to_int payload.[offset] in
          match len with
          | 0 -> Some (List.rev acc, offset + 1)
          | _ when len land 0xc0 = 0xc0 ->
              let pointer = ((len land 0x3f) lsl 8) lor Char.to_int payload.[offset + 1] in
              (match read_name payload pointer [] (depth + 1) with
               | Some (target, _) -> Some (List.rev_append acc target, offset + 2)
               | None -> None)
          | _ ->
              let label = String.sub payload ~pos:(offset + 1) ~len in
              read_name payload (offset + 1 + len) (label :: acc) depth

let is_query_for_us payload =
  match String.length payload >= 12 with
  | false -> false
  | true ->
      let flags = u16_at payload 2 in
      let is_query = flags land 0x8000 = 0 in
      let qdcount = u16_at payload 4 in
      match is_query && qdcount > 0 with
      | false -> false
      | true ->
          match read_name payload 12 [] 0 with
          | None -> false
          | Some (labels, offset) ->
              match offset + 4 <= String.length payload with
              | false -> false
              | true ->
                  let qtype = u16_at payload offset in
                  let qclass = u16_at payload (offset + 2) land 0x7fff in
                  let name =
                    String.concat ~sep:"." labels |> String.lowercase
                  in
                  (qtype = 1 || qtype = 255) && qclass = 1
                  && String.equal name hostname

let build_response ~id ~ip_str =
  let octets =
    String.split ip_str ~on:'.' |> List.map ~f:Int.of_string
  in
  let buf = Buffer.create 128 in
  let add_u16 v =
    Buffer.add_char buf (Char.of_int_exn ((v lsr 8) land 0xff));
    Buffer.add_char buf (Char.of_int_exn (v land 0xff))
  in
  add_u16 id;
  add_u16 0x8400; (* response, authoritative *)
  add_u16 0;
  add_u16 1; (* ancount *)
  add_u16 0;
  add_u16 0;
  (* A record for freetube.local, TTL 120s *)
  Buffer.add_string buf (encode_name hostname);
  add_u16 1;      (* type A *)
  add_u16 0x8001; (* class IN + cache-flush *)
  add_u16 0;
  add_u16 120;    (* TTL *)
  add_u16 4;      (* rdlength *)
  List.iter octets ~f:(fun o -> Buffer.add_char buf (Char.of_int_exn o));
  Buffer.contents buf

let run ~sw ~net ~port =
  let local_ip = Local_ip.for_address ~address:multicast_addr ~port:mdns_port in
  Log.info (fun m -> m "advertising %s -> %s (port %d)" hostname local_ip port);
  let addr = `Udp (Eio.Net.Ipaddr.V4.any, mdns_port) in
  let socket = Eio.Net.datagram_socket ~sw ~reuse_addr:true net addr in
  (match Eio_unix.Resource.fd_opt socket with
   | Some fd -> Eio_unix.Fd.use_exn "mcast-join" fd (fun unix_fd ->
       Unix.setsockopt unix_fd Unix.SO_REUSEPORT true;
       Mcast.join unix_fd multicast_addr "0.0.0.0")
   | None -> failwith "cannot get fd from datagram socket");
  let mcast_dst =
    match Eio.Net.getaddrinfo_datagram net multicast_addr
            ~service:(Int.to_string mdns_port) with
    | dst :: _ -> dst
    | [] -> failwith "cannot resolve mDNS multicast address"
  in
  let buffer = Cstruct.create 4096 in
  let rec loop () =
    let _peer, received = Eio.Net.recv socket buffer in
    let payload = Cstruct.sub buffer 0 received |> Cstruct.to_string in
    (match is_query_for_us payload with
     | false -> ()
     | true ->
         let id = u16_at payload 0 in
         let response = build_response ~id ~ip_str:local_ip in
         (try Eio.Net.send socket ~dst:mcast_dst [ Cstruct.of_string response ]
          with exn ->
            Log.warn (fun m -> m "send failed: %s" (Exn.to_string exn))));
    loop ()
  in
  loop ()
