open! Base
open Js_of_ocaml

(* Service worker for the FreeTube cast extension.

   Listens for [Messages.request] from the content script. For
   [Cast {video_id; device_id}], grabs all .youtube.com cookies and
   POSTs a session to the configured FreeTube server. *)

let log s = Chrome.log ("freetube/bg: " ^ s)

let respond_with respond r =
  let j = Messages.response_to_yojson r in
  let s = Yojson.Safe.to_string j in
  let parsed = Js.Unsafe.fun_call
                 (Js.Unsafe.pure_js_expr "JSON.parse")
                 [| Js.Unsafe.inject (Js.string s) |]
  in
  respond parsed

let handle_list_devices ~respond =
  Api_client.load_server ~k:(fun server ->
    Api_client.get_devices ~server ~k:(function
      | Ok r -> respond_with respond (Devices r)
      | Error e -> respond_with respond (Err e)))

let handle_cast ~respond (m : Messages.cast) =
  Api_client.load_server ~k:(fun server ->
    Cookies_fetch.fetch_youtube ~k:(fun cookies ->
      log (Printf.sprintf "casting %s to %s with %d cookies"
             m.video_id m.device_id (List.length cookies));
      let req : Api.Session_api.create_request =
        {
          source = Youtube_id m.video_id;
          sink = Some m.device_id;
          stream_format = None;
          vcodecs = None;
          acodecs = None;
          cookies = Some cookies;
        }
      in
      Api_client.create_session ~server ~req ~k:(function
        | Ok r ->
            respond_with respond
              (Cast_ok { session_id = r.session_id; url = r.url })
        | Error e -> respond_with respond (Err e))))

let handle_message msg _sender respond =
  let json_str =
    Js.to_string
      (Js.Unsafe.coerce
         (Js.Unsafe.fun_call
            (Js.Unsafe.pure_js_expr "JSON.stringify")
            [| Js.Unsafe.inject msg |]))
  in
  match Yojson.Safe.from_string json_str |> Messages.request_of_yojson with
  | Error e ->
      respond_with respond (Err (Printf.sprintf "bad request: %s" e));
      false
  | Ok List_devices ->
      handle_list_devices ~respond;
      true
  | Ok (Cast m) ->
      handle_cast ~respond m;
      true

let () =
  log "service worker booted";
  Chrome.Runtime.on_message handle_message
