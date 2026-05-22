open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DLNA renderer discovery scan" Stdlib.__MODULE__)

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

let scan ~net ~clock ~client ?timeout () =
  let timeout = Option.value timeout ~default:(Config.get ()).discovery.scan_timeout_seconds in
  Ssdp.discover ~net ~clock ~timeout
  |> List.filter_map ~f:(client_of_response ~client)
