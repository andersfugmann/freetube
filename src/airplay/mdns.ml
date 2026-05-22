open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay mDNS browse" Stdlib.__MODULE__)

let multicast_host = "224.0.0.251"
let multicast_port = 5353
let service_name = "_airplay._tcp.local"

type device = {
  name : string;
  fn : string option;
  address : string;
  port : int;
  pk : string option;
  pi : string;
  features : string option;
  flags : string option;
  model : string option;
  txt : (string * string) list;
}

let friendly_name device =
  match device.fn with
  | Some value -> value
  | None -> device.name

let split_dotted name =
  String.split name ~on:'.' |> List.filter ~f:(Fn.non String.is_empty)

let encode_name name =
  let labels = split_dotted name in
  let label_bytes =
    labels
    |> List.map ~f:(fun label ->
      String.of_char (Char.of_int_exn (String.length label)) ^ label)
    |> String.concat
  in
  label_bytes ^ "\000"

let build_query name qtype =
  let header =
    String.concat
      [ "\000\000";
        "\000\000";
        "\000\001";
        "\000\000";
        "\000\000";
        "\000\000";
      ]
  in
  let q_name = encode_name name in
  let q_type = String.of_char_list [ Char.of_int_exn ((qtype lsr 8) land 0xff); Char.of_int_exn (qtype land 0xff) ] in
  let q_class = "\000\001" in
  header ^ q_name ^ q_type ^ q_class

let byte_at payload offset = Char.to_int payload.[offset]

let u16_at payload offset =
  (byte_at payload offset lsl 8) lor byte_at payload (offset + 1)

let u32_at payload offset =
  (byte_at payload offset lsl 24)
  lor (byte_at payload (offset + 1) lsl 16)
  lor (byte_at payload (offset + 2) lsl 8)
  lor byte_at payload (offset + 3)

let rec read_name payload offset acc depth =
  match depth > 32 with
  | true -> failwith "name pointer loop"
  | false ->
      match offset >= String.length payload with
      | true -> failwith "name overruns payload"
      | false ->
          let len = byte_at payload offset in
          match len with
          | 0 -> List.rev acc, offset + 1
          | _ when len land 0xc0 = 0xc0 ->
              let pointer = ((len land 0x3f) lsl 8) lor byte_at payload (offset + 1) in
              let target, _ = read_name payload pointer [] (depth + 1) in
              List.rev_append acc target, offset + 2
          | _ ->
              let label = String.sub payload ~pos:(offset + 1) ~len in
              read_name payload (offset + 1 + len) (label :: acc) depth

let name_to_string parts = String.concat ~sep:"." parts

let parse_txt payload offset rdlength =
  let stop = offset + rdlength in
  let rec loop offset acc =
    match offset >= stop with
    | true -> List.rev acc
    | false ->
        let len = byte_at payload offset in
        let value = String.sub payload ~pos:(offset + 1) ~len in
        loop (offset + 1 + len) (value :: acc)
  in
  loop offset []

let find_txt_entry txt prefix =
  List.find_map txt ~f:(fun entry ->
    match String.lsplit2 entry ~on:'=' with
    | Some (key, value) when String.equal key prefix -> Some value
    | _ -> None)

type ptr_rec = { ptr_owner : string; ptr_target : string }
type srv_rec = { srv_owner : string; srv_port : int; srv_target : string }
type txt_rec = { txt_owner : string; txt_values : string list }
type a_rec = { a_owner : string; a_address : string }

type record =
  | Ptr of ptr_rec
  | Srv of srv_rec
  | Txt of txt_rec
  | A of a_rec
  | Other

let parse_record payload offset =
  let name, offset = read_name payload offset [] 0 in
  let owner = name_to_string name in
  let rtype = u16_at payload offset in
  let rdlength = u16_at payload (offset + 8) in
  let rdata_offset = offset + 10 in
  let parsed =
    match rtype with
    | 12 ->
        let target_parts, _ = read_name payload rdata_offset [] 0 in
        Ptr { ptr_owner = owner; ptr_target = name_to_string target_parts }
    | 33 ->
        let port = u16_at payload (rdata_offset + 4) in
        let target_parts, _ = read_name payload (rdata_offset + 6) [] 0 in
        Srv { srv_owner = owner; srv_port = port; srv_target = name_to_string target_parts }
    | 16 -> Txt { txt_owner = owner; txt_values = parse_txt payload rdata_offset rdlength }
    | 1 ->
        let addr =
          Stdlib.Printf.sprintf "%d.%d.%d.%d"
            (byte_at payload rdata_offset)
            (byte_at payload (rdata_offset + 1))
            (byte_at payload (rdata_offset + 2))
            (byte_at payload (rdata_offset + 3))
        in
        A { a_owner = owner; a_address = addr }
    | _ -> Other
  in
  parsed, rdata_offset + rdlength

let parse_records payload =
  let qdcount = u16_at payload 4 in
  let ancount = u16_at payload 6 in
  let nscount = u16_at payload 8 in
  let arcount = u16_at payload 10 in
  let total_records = ancount + nscount + arcount in
  let rec skip_questions offset n =
    match n with
    | 0 -> offset
    | _ ->
        let _, offset = read_name payload offset [] 0 in
        skip_questions (offset + 4) (n - 1)
  in
  let offset = skip_questions 12 qdcount in
  let rec loop offset acc n =
    match n with
    | 0 -> List.rev acc
    | _ ->
        let record, offset = parse_record payload offset in
        loop offset (record :: acc) (n - 1)
  in
  loop offset [] total_records

let build_device ~records ~instance =
  let srv =
    List.find_map records ~f:(function
      | Srv r when String.equal r.srv_owner instance -> Some r
      | _ -> None)
  in
  let txt =
    List.find_map records ~f:(function
      | Txt r when String.equal r.txt_owner instance -> Some r.txt_values
      | _ -> None)
    |> Option.value ~default:[]
  in
  match srv with
  | None -> None
  | Some srv ->
      let a =
        List.find_map records ~f:(function
          | A r when String.equal r.a_owner srv.srv_target -> Some r.a_address
          | _ -> None)
      in
      match a with
      | None -> None
      | Some address ->
          let dot = String.index instance '.' |> Option.value ~default:0 in
          let name = String.sub instance ~pos:0 ~len:dot in
          let txt_pairs =
            List.filter_map txt ~f:(fun entry ->
              match String.lsplit2 entry ~on:'=' with
              | Some (k, v) -> Some (k, v)
              | None -> None)
          in
          match find_txt_entry txt "pi" with
          | None -> None
          | Some pi ->
              Some
                {
                  name;
                  fn = find_txt_entry txt "fn";
                  address;
                  port = srv.srv_port;
                  pk = find_txt_entry txt "pk";
                  pi;
                  features = find_txt_entry txt "features";
                  flags = find_txt_entry txt "flags";
                  model = find_txt_entry txt "model";
                  txt = txt_pairs;
                }

let devices_of_records records =
  let instances =
    List.filter_map records ~f:(function
      | Ptr r when String.equal r.ptr_owner (service_name ^ ".") || String.equal r.ptr_owner service_name ->
          Some r.ptr_target
      | _ -> None)
  in
  instances
  |> List.filter_map ~f:(fun instance -> build_device ~records ~instance)

let socket_kind = function
  | `Udp (ip, _) -> Eio.Net.Ipaddr.fold ip ~v4:(fun _ -> `UdpV4) ~v6:(fun _ -> `UdpV6)
  | `Unix _ -> `UdpV4

let first_addr net ~addr ~port =
  Eio.Net.getaddrinfo_datagram net addr ~service:(Int.to_string port)
  |> List.hd

let merge_unique existing new_devices =
  let key device = device.address ^ "|" ^ device.name in
  let known = List.map existing ~f:key |> Set.of_list (module String) in
  let added =
    List.filter new_devices ~f:(fun device -> not (Set.mem known (key device)))
  in
  existing @ added

let browse ~net ~clock ~timeout =
  match first_addr net ~addr:multicast_host ~port:multicast_port with
  | None ->
      Log.err (fun m -> m "Unable to resolve %s:%d" multicast_host multicast_port);
      []
  | Some dst ->
      let query = build_query service_name 12 in
      Eio.Switch.run @@ fun sw ->
      let socket = Eio.Net.datagram_socket ~sw net (socket_kind dst) in
      let buffer = Cstruct.create 65535 in
      let deadline = Eio.Time.now clock +. timeout in
      Eio.Net.send socket ~dst [ Cstruct.of_string query ];
      let rec loop acc =
        let remaining = deadline -. Eio.Time.now clock in
        match Float.(remaining <= 0.) with
        | true -> acc
        | false ->
            (match
               Eio.Time.with_timeout clock remaining (fun () ->
                 Ok (Eio.Net.recv socket buffer))
             with
             | Error `Timeout -> acc
             | Ok (_, received) ->
                 let payload = Cstruct.sub buffer 0 received |> Cstruct.to_string in
                 let records =
                   try parse_records payload with
                   | exn ->
                       Log.debug (fun m -> m "parse failed: %s" (Exn.to_string exn));
                       []
                 in
                 let devices = devices_of_records records in
                 loop (merge_unique acc devices))
      in
      loop []

let _ = u32_at
