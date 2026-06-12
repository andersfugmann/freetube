open! Base
open Util

module Log = (val Log_src.src_log ~doc:"AirPlay protocol discovery" Stdlib.__MODULE__)

type t = {
  start_impl :
    on_added:(Airplay.Client.t -> unit) ->
    on_removed:(id:string -> unit) ->
    unit;
}

let avahi_if_unspec = -1l
let avahi_proto_unspec = -1l

let avahi_server_iface = "org.freedesktop.Avahi.Server"
let avahi_service_browser_iface = "org.freedesktop.Avahi.ServiceBrowser"
let avahi_service = "org.freedesktop.Avahi"
let avahi_root_path = OBus_path.of_string "/"

type service_item = {
  interface : int32;
  protocol : int32;
  name : string;
  service_type : string;
  domain : string;
}

let find_txt txt key =
  List.find_map txt ~f:(fun entry ->
    match String.lsplit2 entry ~on:'=' with
    | Some (k, v) when String.equal k key -> Some v
    | _ -> None)

let parse_txt_pairs txt =
  List.filter_map txt ~f:(fun entry ->
    match String.lsplit2 entry ~on:'=' with
    | Some (k, v) -> Some (k, v)
    | None -> None)

let m_service_browser_new = {
  OBus_member.Method.interface = avahi_server_iface;
  member = "ServiceBrowserNew";
  i_args =
    OBus_value.arg5
      (Some "interface", OBus_value.C.basic_int32)
      (Some "protocol", OBus_value.C.basic_int32)
      (Some "type", OBus_value.C.basic_string)
      (Some "domain", OBus_value.C.basic_string)
      (Some "flags", OBus_value.C.basic_uint32);
  o_args = OBus_value.arg1 (Some "path", OBus_value.C.basic_object_path);
  annotations = [];
}

let m_resolve_service = {
  OBus_member.Method.interface = avahi_server_iface;
  member = "ResolveService";
  i_args =
    OBus_value.arg7
      (Some "interface", OBus_value.C.basic_int32)
      (Some "protocol", OBus_value.C.basic_int32)
      (Some "name", OBus_value.C.basic_string)
      (Some "type", OBus_value.C.basic_string)
      (Some "domain", OBus_value.C.basic_string)
      (Some "aprotocol", OBus_value.C.basic_int32)
      (Some "flags", OBus_value.C.basic_uint32);
  o_args =
    OBus_value.arg11
      (Some "interface", OBus_value.C.basic_int32)
      (Some "protocol", OBus_value.C.basic_int32)
      (Some "name", OBus_value.C.basic_string)
      (Some "type", OBus_value.C.basic_string)
      (Some "domain", OBus_value.C.basic_string)
      (Some "host", OBus_value.C.basic_string)
      (Some "aprotocol", OBus_value.C.basic_int32)
      (Some "address", OBus_value.C.basic_string)
      (Some "port", OBus_value.C.basic_uint16)
      (Some "txt", OBus_value.C.array OBus_value.C.byte_array)
      (Some "flags", OBus_value.C.basic_uint32);
  annotations = [];
}

let m_browser_free = {
  OBus_member.Method.interface = avahi_service_browser_iface;
  member = "Free";
  i_args = OBus_value.arg0;
  o_args = OBus_value.arg0;
  annotations = [];
}

let s_item_new = {
  OBus_member.Signal.interface = avahi_service_browser_iface;
  member = "ItemNew";
  args =
    OBus_value.arg6
      (Some "interface", OBus_value.C.basic_int32)
      (Some "protocol", OBus_value.C.basic_int32)
      (Some "name", OBus_value.C.basic_string)
      (Some "type", OBus_value.C.basic_string)
      (Some "domain", OBus_value.C.basic_string)
      (Some "flags", OBus_value.C.basic_uint32);
  annotations = [];
}

let resolve_service server_proxy item =
  let open Lwt.Syntax in
  let* resolved =
    OBus_method.call m_resolve_service server_proxy
      ( item.interface,
        item.protocol,
        item.name,
        item.service_type,
        item.domain,
        avahi_proto_unspec,
        0l )
  in
  let _, _, name, _, _, _, _, address, port, txt_raw, _ = resolved in
  let txt = parse_txt_pairs txt_raw in
  match find_txt txt_raw "pi" with
  | None -> Lwt.return_none
  | Some pairing_id ->
      Lwt.return_some ({
        Airplay.Client.name = name;
        fn = find_txt txt_raw "fn";
        address;
        port;
        pairing_id;
        public_key = find_txt txt_raw "pk";
        features = find_txt txt_raw "features";
        flags = find_txt txt_raw "flags";
        model = find_txt txt_raw "model";
        txt;
      } : Airplay.Client.t)

let scan_once ~net:_ ~clock:_ ~timeout =
  Eio_unix.run_in_systhread (fun () ->
    let open Lwt.Syntax in
    let compare_item a b =
      let c = Int32.compare a.interface b.interface in
      if not (Int.equal c 0) then c
      else
        let c = Int32.compare a.protocol b.protocol in
        if not (Int.equal c 0) then c
        else
          let c = String.compare a.name b.name in
          if not (Int.equal c 0) then c
          else
            let c = String.compare a.service_type b.service_type in
            if not (Int.equal c 0) then c
            else String.compare a.domain b.domain
    in
    let collect () =
      let* bus = OBus_bus.system () in
      let peer = OBus_peer.make ~connection:bus ~name:avahi_service in
      let server_proxy = OBus_proxy.make ~peer ~path:avahi_root_path in
      let* browser_path =
        OBus_method.call m_service_browser_new server_proxy
          (avahi_if_unspec, avahi_proto_unspec, "_airplay._tcp", "local", 0l)
      in
      let browser_proxy = OBus_proxy.make ~peer ~path:browser_path in
      let* event = OBus_signal.connect (OBus_signal.make s_item_new browser_proxy) in
      let found = ref [] in
      let _subscription =
        React.E.map
          (fun (interface, protocol, name, service_type, domain, _flags) ->
            found := { interface; protocol; name; service_type; domain } :: !found)
          event
      in
      let* () = Lwt_unix.sleep timeout in
      let* () =
        Lwt.catch
          (fun () -> OBus_method.call m_browser_free browser_proxy ())
          (fun _ -> Lwt.return_unit)
      in
      let deduped =
        !found
        |> List.dedup_and_sort ~compare:compare_item
      in
      Lwt_list.filter_map_s (resolve_service server_proxy) deduped
    in
    Lwt_main.run (collect ()))

let scan ~net ~clock ?(timeout = 5.0) () =
  scan_once ~net ~clock ~timeout

let map_of_clients clients =
  List.fold clients ~init:(Map.empty (module String)) ~f:(fun acc client ->
    Map.set acc ~key:(Airplay.Client.pairing_id client) ~data:client)

let start t ~on_added ~on_removed =
  t.start_impl ~on_added ~on_removed

let init ~env ?(timeout = 5.0) ~interval () =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let initial_delay = Float.min 10.0 interval in
  let start_impl ~on_added ~on_removed =
    let known = ref (Map.empty (module String)) in
    let rec loop () =
      (match Result.try_with (fun () -> scan_once ~net ~clock ~timeout) with
       | Error exn ->
           Log.err (fun m -> m "AirPlay discovery scan failed: %s" (Exn.to_string exn))
       | Ok clients ->
           let current = map_of_clients clients in
           Map.iteri current ~f:(fun ~key ~data ->
             match Map.mem !known key with
             | true -> ()
             | false -> on_added data);
           Map.iteri !known ~f:(fun ~key ~data:_ ->
             match Map.mem current key with
             | true -> ()
             | false -> on_removed ~id:key);
           known := current);
      Eio.Time.sleep clock interval;
      loop ()
    in
    Eio.Time.sleep clock initial_delay;
    loop ()
  in
  { start_impl }
