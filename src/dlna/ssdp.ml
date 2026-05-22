open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA SSDP discovery" Stdlib.__MODULE__)

let media_renderer_st = "urn:schemas-upnp-org:device:MediaRenderer:1"
let multicast_host = "239.255.255.250"
let multicast_port = 1900

type search_response = {
  location : string;
  usn : string;
  st : string;
  server : string option;
  cache_max_age : int option;
}

type notification_kind =
  | Alive of {
      location : string;
      usn : string;
      nt : string;
      server : string option;
      max_age : int option;
    }
  | Byebye of { usn : string; nt : string }

let normalize_lines raw =
  raw
  |> String.split ~on:'\n'
  |> List.map ~f:(String.rstrip ~drop:(Char.equal '\r'))

let parse_header line =
  match String.lsplit2 line ~on:':' with
  | Some (name, value) -> Some (String.lowercase name, String.strip value)
  | None -> None

let parse_message raw =
  match normalize_lines raw with
  | start_line :: rest ->
      let headers =
        rest
        |> List.take_while ~f:(Fn.non String.is_empty)
        |> List.filter_map ~f:parse_header
      in
      Some (start_line, headers)
  | [] -> None

let find_header headers name =
  let key = String.lowercase name in
  headers
  |> List.find_map ~f:(fun (header, value) ->
         match String.equal header key with
         | true -> Some value
         | false -> None)

let parse_max_age value =
  value
  |> String.lowercase
  |> String.split ~on:','
  |> List.find_map ~f:(fun part ->
         let part = String.strip part in
         match String.is_prefix part ~prefix:"max-age=" with
         | true ->
             (match Result.try_with (fun () -> String.drop_prefix part 8 |> Int.of_string) with
              | Ok max_age -> Some max_age
              | Error _ -> None)
         | false -> None)

let build_msearch ~st ~mx =
  String.concat ~sep:""
    [
      "M-SEARCH * HTTP/1.1\r\n";
      Printf.sprintf "HOST: %s:%d\r\n" multicast_host multicast_port;
      "MAN: \"ssdp:discover\"\r\n";
      Printf.sprintf "MX: %d\r\n" mx;
      Printf.sprintf "ST: %s\r\n" st;
      "USER-AGENT: FreeTube/1.0 UPnP/2.0\r\n";
      "\r\n";
    ]

let parse_response raw =
  match parse_message raw with
  | Some (status, headers)
    when String.is_prefix (String.lowercase status) ~prefix:"http/1.1 200" ->
      (match find_header headers "location", find_header headers "usn", find_header headers "st" with
       | Some location, Some usn, Some st ->
           Some
             {
               location;
               usn;
               st;
               server = find_header headers "server";
               cache_max_age =
                 find_header headers "cache-control"
                 |> Option.bind ~f:parse_max_age;
             }
       | _ -> None)
  | _ -> None

let parse_notification raw =
  match parse_message raw with
  | Some (request_line, headers)
    when String.is_prefix (String.lowercase request_line) ~prefix:"notify " ->
      (match find_header headers "nts", find_header headers "usn", find_header headers "nt" with
       | Some nts, Some usn, Some nt ->
           (match String.lowercase nts with
            | "ssdp:alive" ->
                find_header headers "location"
                |> Option.map ~f:(fun location ->
                       Alive
                         {
                           location;
                           usn;
                           nt;
                           server = find_header headers "server";
                           max_age =
                             find_header headers "cache-control"
                             |> Option.bind ~f:parse_max_age;
                         })
            | "ssdp:byebye" -> Some (Byebye { usn; nt })
            | _ -> None)
       | _ -> None)
  | _ -> None

let socket_kind = function
  | `Udp (ip, _) -> Eio.Net.Ipaddr.fold ip ~v4:(fun _ -> `UdpV4) ~v6:(fun _ -> `UdpV6)
  | `Unix _ -> `UdpV4

let first_addr net ~addr ~port =
  Eio.Net.getaddrinfo_datagram net addr ~service:(Int.to_string port)
  |> List.hd

let discover_to ~net ~clock ~addr ~port ~timeout =
  match first_addr net ~addr ~port with
  | None ->
      Log.err (fun message -> message "Unable to resolve SSDP address %s:%d" addr port);
      []
  | Some dst ->
      let request = build_msearch ~st:media_renderer_st ~mx:3 in
      Eio.Switch.run @@ fun sw ->
      let socket = Eio.Net.datagram_socket ~sw net (socket_kind dst) in
      let buffer = Cstruct.create 65535 in
      let deadline = Eio.Time.now clock +. timeout in
      Eio.Net.send socket ~dst [ Cstruct.of_string request ];
      let rec loop seen acc =
        let remaining = deadline -. Eio.Time.now clock in
        match Float.(remaining <= 0.) with
        | true -> List.rev acc
        | false ->
            (match
               Eio.Time.with_timeout clock remaining (fun () ->
                   Ok (Eio.Net.recv socket buffer))
             with
             | Error `Timeout -> List.rev acc
             | Ok (_, received) ->
                 let payload = Cstruct.sub buffer 0 received |> Cstruct.to_string in
                 (match parse_response payload with
                  | Some response ->
                      let key = response.usn ^ "|" ^ response.location in
                      (match Set.mem seen key with
                       | true -> loop seen acc
                       | false ->
                           let seen = Set.add seen key in
                           loop seen (response :: acc))
                  | None ->
                      Log.debug (fun message -> message "Ignoring malformed SSDP response");
                      loop seen acc))
      in
      loop (Set.empty (module String)) []

let discover ~net ~clock ~timeout =
  discover_to ~net ~clock ~addr:multicast_host ~port:multicast_port ~timeout

let discover_unicast ~net ~clock ~addr ~port ~timeout =
  discover_to ~net ~clock ~addr ~port ~timeout

let%test "build_msearch uses expected format" =
  String.equal
    (build_msearch ~st:media_renderer_st ~mx:3)
    "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSER-AGENT: FreeTube/1.0 UPnP/2.0\r\n\r\n"

let%test "parse_response extracts SSDP headers" =
  let response =
    String.concat ~sep:""
      [
        "HTTP/1.1 200 OK\r\n";
        "CACHE-CONTROL: max-age=1800\r\n";
        "LOCATION: http://192.168.1.10:1400/xml/device_description.xml\r\n";
        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n";
        "USN: uuid:RINCON_000XXXXXXXXXXXX01400::urn:schemas-upnp-org:device:MediaRenderer:1\r\n";
        "SERVER: Linux/5.10 UPnP/1.0 Sonos/57.3-79200\r\n";
        "\r\n";
      ]
  in
  match parse_response response with
  | Some { location; usn; st; server = Some server; cache_max_age = Some 1800 } ->
      String.equal location "http://192.168.1.10:1400/xml/device_description.xml"
      && String.equal st media_renderer_st
      && String.is_substring usn ~substring:"uuid:RINCON"
      && String.equal server "Linux/5.10 UPnP/1.0 Sonos/57.3-79200"
  | _ -> false
