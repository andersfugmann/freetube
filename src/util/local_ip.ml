open! Base

let local_ip_for_dst ~net dst =
  let bind_addr =
    match dst with
    | `Udp (ip, _) ->
        Eio.Net.Ipaddr.fold ip
          ~v4:(fun _ -> `Udp (Eio.Net.Ipaddr.V4.any, 0))
          ~v6:(fun _ -> `Udp (Eio.Net.Ipaddr.V6.any, 0))
    | `Unix _ -> failwith "unexpected unix sockaddr"
  in
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.datagram_socket ~sw net bind_addr
  in
  let fd = Eio_unix.Net.fd socket in
  Eio_unix.Fd.use_exn "local-ip-connect" fd (fun unix_fd ->
    Unix.connect unix_fd (Eio_unix.Net.sockaddr_to_unix dst);
    match Unix.getsockname unix_fd with
    | Unix.ADDR_INET (local, _) -> Unix.string_of_inet_addr local
    | Unix.ADDR_UNIX _ -> failwith "unexpected unix sockaddr")

let find_datagram_dst ~net ~address ~port ~want_v6 =
  let service = Int.to_string port in
  Eio.Net.getaddrinfo_datagram net address ~service
  |> List.find ~f:(fun dst ->
       match dst with
       | `Udp (ip, _) ->
           Eio.Net.Ipaddr.fold ip ~v4:(fun _ -> not want_v6)
             ~v6:(fun _ -> want_v6)
       | `Unix _ -> false)

let for_peer ~net : Eio.Net.Sockaddr.stream -> Eio.Net.Ipaddr.v4v6 = function
  | `Unix _ -> (Eio.Net.Ipaddr.V4.loopback :> Eio.Net.Ipaddr.v4v6)
  | `Tcp (ip, _) ->
      let local =
       local_ip_for_dst ~net (`Udp (ip, 1))
       |> Unix.inet_addr_of_string
      in
      Eio_unix.Net.Ipaddr.of_unix local

let for_address ~net ~address ~port =
  match find_datagram_dst ~net ~address ~port ~want_v6:false with
  | Some dst -> local_ip_for_dst ~net dst
  | None -> failwith "cannot resolve IPv4 destination address"

let for_address_v6 ~net ~address ~port =
  match find_datagram_dst ~net ~address ~port ~want_v6:true with
  | Some dst -> local_ip_for_dst ~net dst
  | None -> failwith "cannot resolve IPv6 destination address"

let for_address_v6_opt ~net ~address ~port =
  match find_datagram_dst ~net ~address ~port ~want_v6:true with
  | None -> None
  | Some dst ->
      (try Some (local_ip_for_dst ~net dst)
  with
      | Unix.Unix_error _ -> None)

let host_ipv6 ~net () =
  Eio.Net.getaddrinfo_datagram net (Unix.gethostname ()) ~service:"0"
  |> List.find_map ~f:(function
       | `Udp (ip, _) ->
          Eio.Net.Ipaddr.fold ip
            ~v4:(fun _ -> None)
            ~v6:(fun _ ->
              let ip_str = Stdlib.Format.asprintf "%a" Eio.Net.Ipaddr.pp ip in
              match ip_str with
              | "::1" -> None
              | _ -> Some ip_str)
       | `Unix _ -> None)
