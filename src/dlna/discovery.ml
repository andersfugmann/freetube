open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA renderer discovery scan" Stdlib.__MODULE__)

type t = {
  start_impl :
    on_added:(Dlna.Client.t -> unit) ->
    on_removed:(id:string -> unit) ->
    unit;
}

let ip_version_of_uri uri =
  match Uri.host uri with
  | Some host when String.is_prefix host ~prefix:"[" -> `V6
  | Some host when String.mem host ':' -> `V6
  | _ -> `V4

let fetch_description ~client location =
  match
    Result.try_with (fun () ->
      let uri = Uri.of_string location in
      Http_client.get client ~ip_version:(ip_version_of_uri uri) ~oneshot:true uri)
  with
  | Error exn ->
      Log.debug (fun m -> m "Failed to fetch %s: %s" location (Exn.to_string exn));
      None
  | Ok response ->
      match response.status with
        | 200 ->
          (match Device_description.parse ~location ~xml:response.body with
           | Ok client -> Some client
           | Error error ->
               Log.debug (fun m -> m "Failed to parse %s: %s" location error);
               None)
      | status ->
          Log.debug (fun m -> m "Non-OK response fetching %s: %d" location status);
          None

let client_of_response ~client (response : Ssdp.search_response) =
  fetch_description ~client response.location

let scan ~net ~clock ~client ~timeout () =
  Ssdp.discover ~net ~clock ~timeout
  |> List.filter_map ~f:(client_of_response ~client)

let map_of_clients clients =
  List.fold clients ~init:(Map.empty (module String)) ~f:(fun acc client ->
    Map.set acc ~key:(Dlna.Client.udn client) ~data:client)

let start t ~on_added ~on_removed =
  t.start_impl ~on_added ~on_removed

let init ~env ~interval () =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let timeout =
    (Config.get ()).discovery.scan_timeout_seconds
  in
  let start_impl ~on_added ~on_removed =
    Eio.Switch.run @@ fun sw ->
    let client =
      Http_client.init
        ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
        ~sw ~env ()
    in
    let known = ref (Map.empty (module String)) in
    let rec loop () =
      (match Result.try_with (fun () -> scan ~net ~clock ~client ~timeout ()) with
       | Error exn ->
           Log.err (fun m -> m "DLNA discovery scan failed: %s" (Exn.to_string exn))
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
    loop ()
  in
  { start_impl }
