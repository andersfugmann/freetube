open! Base
open Devices
open Util
open Json_io.Let_syntax

module Log = (val Log_src.src_log ~doc:"AirPlay HTTP endpoints" Stdlib.__MODULE__)

let respond_json ~status ~json = Json_io.respond_json ~status json
let respond_string = Json_io.respond_string

let handle_pair_start_json ~(app : _ App.t) parsed =
  let env = app.env in
  let sw = app.sw in
  let@! request =
    Json_io.parse_of_yojson Api.Airplay_pairing.pair_start_request_of_yojson parsed,
    (`Bad_request, "AirPlay pairing") in
  Log.info (fun m -> m "Pair start for device %s" request.device_id);
  let entry =
    Device_store.all app.device_store
    |> List.find ~f:(fun (e : Device.t) ->
         match e.client with
         | Airplay c -> String.equal c.pairing_id request.device_id
         | _ -> false)
    |> Option.value_or_thunk ~default:(fun () ->
         Json_io.raise_http `Not_found
           (Printf.sprintf "AirPlay pairing: device %s not found" request.device_id))
  in
  let airplay_client = match entry.client with
    | Airplay c -> c
    | _ -> assert false
  in
  match
    Result.try_with (fun () ->
      Airplay_pairing.start ~env ~sw
        ~address:airplay_client.address
        ~port:airplay_client.port
        ~receiver_pairing_id:airplay_client.pairing_id)
  with
  | Error exn ->
      Log.err (fun m -> m "Pair start failed: %s" (Exn.to_string exn));
      respond_string ~status:`Bad_gateway
        (Printf.sprintf "AirPlay pairing failed: %s" (Exn.to_string exn))
  | Ok session_id ->
      respond_json ~status:`OK
        ~json:(Api.Airplay_pairing.pair_start_response_to_yojson { session_id })

let handle_pair_finish_json ~fs ~clock:_ parsed =
  let@! request =
    Json_io.parse_of_yojson Api.Airplay_pairing.pair_finish_request_of_yojson parsed,
    (`Bad_request, "AirPlay PIN verification") in
  Log.info (fun m -> m "PIN verification for session %s" request.session_id);
  match Airplay_pairing.submit_pin ~session_id:request.session_id ~pin:request.pin with
  | Error message ->
      respond_string ~status:`Not_found
        (Printf.sprintf "AirPlay PIN verification: %s" message)
  | Ok (Error err) ->
      let message = Airplay_protocol.Error.to_string err in
      Log.err (fun m -> m "PIN verification failed: %s" message);
      let status : Piaf.Status.t =
        match err with
        | Auth_failed _ -> `Unauthorized
        | _ -> `Bad_gateway
      in
      respond_string ~status
        (Printf.sprintf "AirPlay PIN verification failed: %s" message)
  | Ok (Ok credentials) ->
      Airplay_credentials.save ~fs credentials;
      let pairing_id = Airplay_protocol.Pairing.pairing_id credentials in
      let response : Api.Airplay_pairing.pair_finish_response = { pairing_id } in
      respond_json ~status:`OK
        ~json:(Api.Airplay_pairing.pair_finish_response_to_yojson response)

let handle_pair ~(app : _ App.t) request =
  let@! payload = Json_io.read_body request, (`Bad_request, "AirPlay pairing") in
  let@! parsed = Json_io.parse_json payload, (`Bad_request, "AirPlay pairing") in
  let has_session_id =
    match parsed with
    | `Assoc fields -> List.exists fields ~f:(fun (k, _) -> String.equal k "session_id")
    | _ -> false
  in
  match has_session_id with
  | true -> handle_pair_finish_json ~fs:(Eio.Stdenv.fs app.env) ~clock:() parsed
  | false -> handle_pair_start_json ~app parsed
