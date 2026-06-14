open! Base
open Devices
open Util
open Json_io.Let_syntax

module Log = (val Log_src.src_log ~doc:"AirPlay HTTP endpoints" Stdlib.__MODULE__)

let respond_json json =
  Response.ok ~content_type:(Explicit "application/json")
    (Yojson.Safe.to_string json)

let respond_string body =
  Response.ok ~content_type:No_content_type body

let handle_pair_start_json ~(app : _ App.t) parsed =
  let env = app.env in
  let sw = app.sw in
  let@! request =
    Json_io.parse_of_yojson Api.Airplay_pairing.pair_start_request_of_yojson parsed,
    "AirPlay pairing" in
  Log.info (fun m -> m "Pair start for device %s" request.device_id);
  match
    Device_store.all app.device_store
    |> List.find ~f:(fun entry ->
       let (e : Device.t) = Device.entry_device entry in
        match e.client with
         | Airplay c -> String.equal c.pairing_id request.device_id
         | _ -> false)
  with
  | None -> Error `Not_found
  | Some found ->
     let (entry : Device.t) = Device.entry_device found in
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
         Error (`Upstream_error (Printf.sprintf "AirPlay pairing failed: %s" (Exn.to_string exn)))
     | Ok session_id ->
         Ok (respond_json (Api.Airplay_pairing.pair_start_response_to_yojson { session_id }))

let handle_pair_finish_json ~fs ~clock:_ parsed =
  let@! request =
    Json_io.parse_of_yojson Api.Airplay_pairing.pair_finish_request_of_yojson parsed,
    "AirPlay PIN verification" in
  Log.info (fun m -> m "PIN verification for session %s" request.session_id);

  let submit_pin_result =
    let ( let* ) result f = Result.bind result ~f in
    let* result =
      Airplay_pairing.submit_pin ~session_id:request.session_id ~pin:request.pin
      |> Result.map_error ~f:(fun message -> `Session message)
    in
    result |> Result.map_error ~f:(fun err -> `Pairing err)
  in
  match submit_pin_result with
  | Error (`Session _) ->
      Error (`Not_found)
  | Error (`Pairing err) ->
      let message = Airplay_protocol.Error.to_string err in
      Log.err (fun m -> m "PIN verification failed: %s" message);
      (match err with
       | Auth_failed _ ->
           Error (`Unauthorized (Printf.sprintf "AirPlay PIN verification failed: %s" message))
       | _ ->
           Error (`Upstream_error (Printf.sprintf "AirPlay PIN verification failed: %s" message)))
  | Ok credentials ->
      Airplay_credentials.save ~fs credentials;
      let pairing_id = Airplay_protocol.Pairing.pairing_id credentials in
      let response : Api.Airplay_pairing.pair_finish_response = { pairing_id } in
      Ok (respond_json (Api.Airplay_pairing.pair_finish_response_to_yojson response))

let handle_pair ~(app : _ App.t) request =
  let@! payload = Json_io.read_body request, "AirPlay pairing" in
  let@! parsed = Json_io.parse_json payload, "AirPlay pairing" in
  let has_session_id =
    match parsed with
    | `Assoc fields -> List.exists fields ~f:(fun (k, _) -> String.equal k "session_id")
    | _ -> false
  in
  match has_session_id with
  | true -> handle_pair_finish_json ~fs:(Eio.Stdenv.fs app.env) ~clock:() parsed
  | false -> handle_pair_start_json ~app parsed
