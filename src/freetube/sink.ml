open! Base
open Util
open Devices

module Log = (val Log_src.src_log ~doc:"Sink dispatch" Stdlib.__MODULE__)

(* Sinks attach to a Client_session and consume the master URL. A
   Url_consumer is what HTTP clients (CLI, browser) request when they
   want a URL to pull themselves; it has no control channel. The
   other variants wrap an active control session to a remote
   renderer. *)

type t =
  | Url_consumer
  | Airplay of {
      device : Airplay.Client.t;
      session : Airplay_protocol.Session.t;
      vendor : Vendor.t;
    }
  | Dlna of {
      client : Dlna.Client.t;
      title : string;
      mime : Dlna_protocol.Mime.t;
      session : Dlna_protocol.Session.t;
      vendor : Vendor.t;
      duration_seconds : float option;
      resolution : (int * int) option;
      is_live : bool;
    }

(* A control operation failure, unifying the recoverable error taxonomies of
   the two protocol libraries with the local "not a control sink" case.
   Consumers pattern-match to choose an HTTP status. *)
type error =
  | Not_controllable
  | Airplay_error of Airplay_protocol.Error.t
  | Dlna_error of Dlna_protocol.Error.t

let error_to_string = function
  | Not_controllable -> "sink not controllable"
  | Airplay_error e -> Airplay_protocol.Error.to_string e
  | Dlna_error e -> Dlna_protocol.Error.to_string e

type kind = [ `Url | `Airplay | `Dlna ]

let kind = function
  | Url_consumer -> `Url
  | Airplay _    -> `Airplay
  | Dlna _       -> `Dlna

let kind_to_string = function
  | `Url     -> "url"
  | `Airplay -> "airplay"
  | `Dlna    -> "dlna"

let controllable = function
  | Url_consumer -> false
  | Airplay _ | Dlna _ -> true

let play t ~url =
  match t with
  | Url_consumer -> Ok ()
  | Airplay { device; session; _ } ->
      Log.info (fun m ->
        m "play -> airplay %s (%s:%d) url=%s"
          (Airplay.Client.friendly_name device)
          (Airplay.Client.address device) (Airplay.Client.port device) url);
      Airplay_protocol.Session.play session ~content_url:url
      |> Result.map_error ~f:(fun e -> Airplay_error e)
  | Dlna { session; title; mime; client; duration_seconds; resolution; is_live; _ } ->
      Log.info (fun m ->
        m "play -> dlna %s mime=%s title=%s url=%s"
          (Dlna.Client.friendly_name client)
          (Dlna_protocol.Mime.to_string mime)
          title url);
      Dlna_protocol.Session.play session ~content_url:url ~title ~mime
        ~duration_seconds ~resolution ~is_live
      |> Result.map_error ~f:(fun e -> Dlna_error e)

let pause = function
  | Url_consumer -> Error Not_controllable
  | Airplay { session; _ } ->
      Airplay_protocol.Session.pause session |> Result.map_error ~f:(fun e -> Airplay_error e)
  | Dlna { session; _ } ->
      Dlna_protocol.Session.pause session |> Result.map_error ~f:(fun e -> Dlna_error e)

let resume = function
  | Url_consumer -> Error Not_controllable
  | Airplay { session; _ } ->
      Airplay_protocol.Session.resume session |> Result.map_error ~f:(fun e -> Airplay_error e)
  | Dlna { session; _ } ->
      Dlna_protocol.Session.resume session |> Result.map_error ~f:(fun e -> Dlna_error e)

let seek t ~seconds =
  match t with
  | Url_consumer -> Error Not_controllable
  | Airplay { session; _ } ->
      Airplay_protocol.Session.seek session ~seconds |> Result.map_error ~f:(fun e -> Airplay_error e)
  | Dlna { session; _ } ->
      Dlna_protocol.Session.seek session ~seconds |> Result.map_error ~f:(fun e -> Dlna_error e)

let close = function
  | Url_consumer -> ()
  | Airplay { session; _ } -> Airplay_protocol.Session.stop session
  | Dlna { session; _ } -> (match Dlna_protocol.Session.stop session with _ -> ())

let friendly_name = function
  | Url_consumer -> None
  | Airplay { device; _ } -> Some (Airplay.Client.friendly_name device)
  | Dlna { client; _ } -> Some (Dlna.Client.friendly_name client)

let terminated = function
  | Airplay { session; _ } -> Some (Airplay_protocol.Session.terminated session)
  | Dlna { session; _ } -> Some (Dlna_protocol.Session.terminated session)
  | Url_consumer -> None

let airplay ~env ~sw ~device ~vendor ~ntp =
  let credentials =
    match Airplay_credentials.load ~pairing_id:(Airplay.Client.pairing_id device) with
    | Some entry -> entry
    | None ->
        Printf.failwithf "No stored AirPlay credentials for %s (pair first)"
          (Airplay.Client.friendly_name device) ()
  in
  match Airplay_protocol.Session.connect ~env ~sw ~client:device ~credentials ~ntp with
  | Ok session -> Airplay { device; session; vendor }
  | Error err -> failwith (Airplay_protocol.Error.to_string err)

let probe_airplay ~env ~(client : Airplay.Client.t) =
  let pairing_id = client.pairing_id in
  match Airplay_credentials.load ~pairing_id with
  | None -> Error `No_credentials
  | Some credentials ->
    let net = Eio.Stdenv.net env in
    match
      Eio.Switch.run (fun sw ->
        let _stream, _keys =
          Airplay_protocol.Pair_verify_driver.run ~net ~sw
            ~address:client.address ~port:client.port ~credentials
        in
        ())
    with
    | () -> Ok ()
    | exception (Eio.Io _ as exn) -> Error (`Unavailable (Exn.to_string exn))
    | exception exn -> Error (`Invalid_credentials (Exn.to_string exn))

let dlna ~env ~sw ~client ~title ~mime ~vendor
      ?duration_seconds ?resolution ?(is_live = false) () =
  let session = Dlna_protocol.Session.connect ~env ~sw ~client in
  Dlna { client; title; mime; session; vendor;
         duration_seconds; resolution; is_live }

let vendor = function
  | Url_consumer -> Vendor.Generic
  | Airplay { vendor; _ } -> vendor
  | Dlna { vendor; _ } -> vendor

let url_consumer = Url_consumer
