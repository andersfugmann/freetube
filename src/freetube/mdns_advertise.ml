open! Base
open Util

module Log = (val Log_src.src_log ~doc:"mDNS service advertisement" Stdlib.__MODULE__)

let normalize_hostname hostname =
  hostname
  |> String.strip
  |> String.rstrip ~drop:(Char.equal '.')
  |> String.lowercase

let service_instance_name hostname =
  hostname
  |> String.split ~on:'.'
  |> List.find ~f:(Fn.non String.is_empty)
  |> Option.value ~default:"freetube"

let avahi_if_unspec = -1l
let avahi_proto_unspec = -1l
let publish_no_reverse = 16l

let avahi_server_iface = "org.freedesktop.Avahi.Server"
let avahi_group_iface = "org.freedesktop.Avahi.EntryGroup"
let avahi_service = "org.freedesktop.Avahi"
let avahi_root_path = OBus_path.of_string "/"

let m_entry_group_new = {
  OBus_member.Method.interface = avahi_server_iface;
  member = "EntryGroupNew";
  i_args = OBus_value.arg0;
  o_args = OBus_value.arg1 (Some "path", OBus_value.C.basic_object_path);
  annotations = [];
}

let m_group_add_service = {
  OBus_member.Method.interface = avahi_group_iface;
  member = "AddService";
  i_args =
    OBus_value.arg9
      (Some "interface", OBus_value.C.basic_int32)
      (Some "protocol", OBus_value.C.basic_int32)
      (Some "flags", OBus_value.C.basic_uint32)
      (Some "name", OBus_value.C.basic_string)
      (Some "type", OBus_value.C.basic_string)
      (Some "domain", OBus_value.C.basic_string)
      (Some "host", OBus_value.C.basic_string)
      (Some "port", OBus_value.C.basic_uint16)
      (Some "txt", OBus_value.C.array OBus_value.C.byte_array);
  o_args = OBus_value.arg0;
  annotations = [];
}

let m_group_add_address = {
  OBus_member.Method.interface = avahi_group_iface;
  member = "AddAddress";
  i_args =
    OBus_value.arg5
      (Some "interface", OBus_value.C.basic_int32)
      (Some "protocol", OBus_value.C.basic_int32)
      (Some "flags", OBus_value.C.basic_uint32)
      (Some "name", OBus_value.C.basic_string)
      (Some "address", OBus_value.C.basic_string);
  o_args = OBus_value.arg0;
  annotations = [];
}

let m_group_commit = {
  OBus_member.Method.interface = avahi_group_iface;
  member = "Commit";
  i_args = OBus_value.arg0;
  o_args = OBus_value.arg0;
  annotations = [];
}

let run_lwt ~port ~hostname ~service ~local_ipv4 ~local_ipv6 =
  let open Lwt.Syntax in
  let* bus = OBus_bus.system () in
  let peer = OBus_peer.make ~connection:bus ~name:avahi_service in
  let server_proxy = OBus_proxy.make ~peer ~path:avahi_root_path in
  let* group_path = OBus_method.call m_entry_group_new server_proxy () in
  let group_proxy = OBus_proxy.make ~peer ~path:group_path in
  let* () =
    OBus_method.call m_group_add_service group_proxy
      ( avahi_if_unspec,
        avahi_proto_unspec,
        0l,
        service,
        "_http._tcp",
        "",
        "",
        port,
        [ "path=/" ] )
  in
  let* () =
    OBus_method.call m_group_add_address group_proxy
      (avahi_if_unspec, avahi_proto_unspec, publish_no_reverse, hostname, local_ipv4)
  in
  let* () =
    match local_ipv6 with
    | None -> Lwt.return_unit
    | Some ip ->
        OBus_method.call m_group_add_address group_proxy
          (avahi_if_unspec, avahi_proto_unspec, publish_no_reverse, hostname, ip)
  in
  OBus_method.call m_group_commit group_proxy ()

let run ~sw:_ ~env ~port ~hostname =
  let hostname = normalize_hostname hostname in
  (match String.is_empty hostname with
   | true -> failwith "mDNS hostname must not be empty"
   | false -> ());
  let net = Eio.Stdenv.net env in
  let local_ipv4 =
    Local_ip.for_address ~net ~address:"224.0.0.251" ~port:5353
  in
  let local_ipv6 =
    match Local_ip.host_ipv6 ~net () with
    | Some ip -> Some ip
    | None ->
        Local_ip.for_address_v6_opt ~net ~address:"2001:4860:4860::8888"
          ~port:53
  in
  let service = service_instance_name hostname in
  (match local_ipv6 with
   | Some ipv6 ->
       Log.info (fun m ->
         m "advertising via avahi dbus: %s + %s -> %s and %s (port %d)" hostname
           service local_ipv4 ipv6 port)
   | None ->
       Log.info (fun m ->
         m "advertising via avahi dbus: %s + %s -> %s (port %d)" hostname service
           local_ipv4 port));
  Eio_unix.run_in_systhread (fun () ->
    Lwt_main.run (run_lwt ~port ~hostname ~service ~local_ipv4 ~local_ipv6))
