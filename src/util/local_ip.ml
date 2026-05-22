open! Base

let for_peer : Eio.Net.Sockaddr.stream -> Eio.Net.Ipaddr.v4v6 = function
  | `Unix _ -> (Eio.Net.Ipaddr.V4.loopback :> Eio.Net.Ipaddr.v4v6)
  | `Tcp (ip, _) ->
      let peer_unix = Eio_unix.Net.Ipaddr.to_unix ip in
      let socket =
        Unix.socket
          (Unix.domain_of_sockaddr (Unix.ADDR_INET (peer_unix, 1)))
          Unix.SOCK_DGRAM 0
      in
      Exn.protect
        ~f:(fun () ->
          Unix.connect socket (Unix.ADDR_INET (peer_unix, 1));
          match Unix.getsockname socket with
          | Unix.ADDR_INET (local, _) -> Eio_unix.Net.Ipaddr.of_unix local
          | Unix.ADDR_UNIX _ -> failwith "unexpected unix sockaddr")
        ~finally:(fun () -> Unix.close socket)

let for_address ~address ~port =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
  Exn.protect
    ~f:(fun () ->
      let addr =
        match Unix.inet_addr_of_string address with
        | addr -> addr
        | exception _ -> (Unix.gethostbyname address).h_addr_list.(0)
      in
      Unix.connect socket (Unix.ADDR_INET (addr, port));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (local, _) -> Unix.string_of_inet_addr local
      | Unix.ADDR_UNIX _ -> failwith "unexpected unix sockaddr")
    ~finally:(fun () -> Unix.close socket)
