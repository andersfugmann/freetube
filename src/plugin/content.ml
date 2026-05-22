open! Base
open Js_of_ocaml

(* Content script: injects a cast button into the YouTube player and
   shows a picker overlay populated from the FreeTube server. *)

let log s = Chrome.log ("freetube/ct: " ^ s)

let set_attr e k v =
  (Js.Unsafe.coerce e : Dom_html.element Js.t)##setAttribute
    (Js.string k) (Js.string v)

let set_html e html =
  Js.Unsafe.set e (Js.string "innerHTML") (Js.string html)

let document = Dom_html.document

let by_id id =
  Js.Opt.to_option (document##getElementById (Js.string id))

let remove_existing id =
  match by_id id with
  | Some e -> Js.Opt.iter e##.parentNode (fun p -> Dom.removeChild p e)
  | None -> ()

let video_id_of_location () =
  let search = Js.to_string Dom_html.window##.location##.search in
  let pairs =
    String.chop_prefix ~prefix:"?" search
    |> Option.value ~default:search
    |> String.split ~on:'&'
  in
  List.find_map pairs ~f:(fun kv ->
      match String.lsplit2 kv ~on:'=' with
      | Some ("v", v) -> Some v
      | _ -> None)

let send_request req ~k =
  let s = Yojson.Safe.to_string (Messages.request_to_yojson req) in
  let parsed =
    Js.Unsafe.fun_call
      (Js.Unsafe.pure_js_expr "JSON.parse")
      [| Js.Unsafe.inject (Js.string s) |]
  in
  Chrome.Runtime.send_message ~msg:parsed ~k:(fun resp ->
    let json_str =
      Js.to_string
        (Js.Unsafe.coerce
           (Js.Unsafe.fun_call
              (Js.Unsafe.pure_js_expr "JSON.stringify")
              [| Js.Unsafe.inject resp |]))
    in
    match Yojson.Safe.from_string json_str |> Messages.response_of_yojson with
    | Ok r -> k r
    | Error e -> k (Err e))

let toast ~ok msg =
  remove_existing "freetube-toast";
  let div = Dom_html.createDiv document in
  set_attr div "id" "freetube-toast";
  let bg = if ok then "#1e7e34" else "#a02020" in
  set_attr div "style"
    (Printf.sprintf
       "position:fixed;bottom:24px;left:50%%;transform:translateX(-50%%);\
        background:%s;color:#fff;padding:10px 18px;border-radius:6px;\
        z-index:2147483647;font-family:Roboto,Arial,sans-serif;font-size:14px;"
       bg);
  div##.textContent := Js.some (Js.string msg);
  Dom.appendChild document##.body div;
  let _ =
    Js.Unsafe.fun_call (Js.Unsafe.pure_js_expr "setTimeout")
      [| Js.Unsafe.inject
           (Js.wrap_callback (fun () -> remove_existing "freetube-toast"))
       ; Js.Unsafe.inject 3500.0 |]
  in
  ()

let close_picker () = remove_existing "freetube-picker"

let cast_to ~device_id =
  match video_id_of_location () with
  | None -> toast ~ok:false "No video on this page"
  | Some video_id ->
      toast ~ok:true "Casting...";
      send_request (Cast { video_id; device_id }) ~k:(function
        | Cast_ok _ -> toast ~ok:true "Casting started"
        | Err e -> toast ~ok:false ("Cast failed: " ^ e)
        | Devices _ -> toast ~ok:false "Unexpected response")

(* Inline SVG glyphs (currentColor) matching the popup device list. *)
let device_icon (d : Device.t) =
  match d.client with
  | Airplay _ ->
      "<svg viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" \
       fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" \
       stroke-linecap=\"round\" stroke-linejoin=\"round\" \
       style=\"flex:none;opacity:0.8;\">\
       <path d=\"M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1\"/>\
       <polygon points=\"12 15 17 21 7 21 12 15\"/></svg>"
  | Dlna _ | Url ->
      "<svg viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" \
       fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" \
       stroke-linecap=\"round\" stroke-linejoin=\"round\" \
       style=\"flex:none;opacity:0.8;\">\
       <path d=\"M2 16.1A5 5 0 0 1 5.9 20M2 12.05A9 9 0 0 1 9.95 20\
       M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6\"/>\
       <line x1=\"2\" y1=\"20\" x2=\"2.01\" y2=\"20\"/></svg>"

let render_picker ?(loading=false) (devs : Device.list_response) =
  remove_existing "freetube-picker";
  let now =
    Js.to_float (new%js Js.date_now)##getTime /. 1000.
  in
  let overlay = Dom_html.createDiv document in
  set_attr overlay "id" "freetube-picker";
  set_attr overlay "style"
    "position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.6);\
     z-index:2147483647;display:flex;align-items:center;justify-content:center;\
     font-family:Roboto,Arial,sans-serif;";
  let onclick =
    Dom_html.handler (fun ev ->
      Js.Opt.iter ev##.target (fun t ->
        let id = Js.to_string t##.id in
        match String.equal id "freetube-picker" with
        | true -> close_picker ()
        | false -> ());
      Js._true)
  in
  overlay##.onclick := onclick;
  let panel = Dom_html.createDiv document in
  set_attr panel "style"
    "background:#202020;color:#fff;border-radius:8px;min-width:320px;\
     max-width:90%;max-height:80%;overflow:auto;padding:16px;";
  let title = Dom_html.createH3 document in
  title##.textContent := Js.some (Js.string "Cast to device");
  set_attr title "style" "margin:0 0 12px 0;font-size:16px;";
  Dom.appendChild panel title;
  let sorted =
    List.sort devs.devices ~compare:(fun a b ->
      String.compare
        (String.lowercase a.friendly_name)
        (String.lowercase b.friendly_name))
  in
  List.iter sorted ~f:(fun (d : Device.t) ->
    let row = Dom_html.createButton document in
    set_attr row "style"
      "display:flex;align-items:center;gap:10px;width:100%;text-align:left;\
       background:#303030;color:#fff;border:none;border-radius:4px;\
       padding:10px 12px;margin:4px 0;cursor:pointer;font-size:14px;";
    let kind = Device.kind d in
    let name = d.friendly_name in
    let brand = Api.Vendor.to_string d.vendor in
    let icon = device_icon d in
    let online = Float.(now -. d.last_seen < 120.) in
    let dot_style =
      match online with
      | true -> "display:inline-block;width:8px;height:8px;border-radius:50%;background:#4caf50;margin-left:4px;vertical-align:middle;"
      | false -> "display:inline-block;width:8px;height:8px;border-radius:50%;background:#555;margin-left:4px;vertical-align:middle;"
    in
    set_html row
      (Printf.sprintf
         "%s<span><strong>%s</strong><span style=\"%s\"></span> \
          <span style=\"opacity:0.6;font-size:12px;\">[%s · %s]</span></span>"
         icon name dot_style kind brand);
    row##.onclick := Dom_html.handler (fun _ ->
      close_picker ();
      cast_to ~device_id:d.id;
      Js._true);
    Dom.appendChild panel row);
  (match loading, List.is_empty devs.devices with
   | true, _ ->
       let msg = Dom_html.createDiv document in
       msg##.textContent := Js.some (Js.string "Loading devices…");
       set_attr msg "style" "opacity:0.7;font-size:13px;padding:8px 0;";
       Dom.appendChild panel msg
   | false, true ->
       let empty = Dom_html.createDiv document in
       empty##.textContent := Js.some (Js.string "No devices found");
       set_attr empty "style" "opacity:0.7;font-size:13px;padding:8px 0;";
       Dom.appendChild panel empty
   | false, false -> ());
  Dom.appendChild overlay panel;
  Dom.appendChild document##.body overlay

let open_picker () =
  render_picker ~loading:true { devices = [] };
  send_request List_devices ~k:(function
    | Devices d -> render_picker d
    | Err e -> toast ~ok:false ("List devices failed: " ^ e)
    | Cast_ok _ -> toast ~ok:false "Unexpected response")

let cast_svg =
  "<svg width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"#fff\" \
   style=\"display:block;\">\
   <path d=\"M21 3H3c-1.1 0-2 .9-2 2v3h2V5h18v14h-7v2h7c1.1 0 2-.9 2-2V5\
   c0-1.1-.9-2-2-2zM1 18v3h3c0-1.66-1.34-3-3-3zm0-4v2c2.76 0 5 2.24 5 5h2\
   c0-3.87-3.13-7-7-7zm0-4v2c4.97 0 9 4.03 9 9h2c0-6.08-4.93-11-11-11z\"/>\
   </svg>"

let try_inject () =
  match by_id "freetube-cast-btn" with
  | Some _ -> ()
  | None ->
      let controls =
        document##querySelector (Js.string ".ytp-right-controls")
      in
      Js.Opt.iter controls (fun ctrls ->
        let btn = Dom_html.createButton document in
        set_attr btn "id" "freetube-cast-btn";
        set_attr btn "class" "ytp-button";
        set_attr btn "title" "Cast to FreeTube";
        set_attr btn "aria-label" "Cast to FreeTube";
        set_attr btn "style"
          "width:48px;height:100%;display:inline-flex;align-items:center;\
           justify-content:center;padding:0;border:0;background:transparent;\
           cursor:pointer;opacity:0.9;vertical-align:top;";
        set_html btn cast_svg;
        btn##.onclick := Dom_html.handler (fun _ ->
          open_picker ();
          Js._true);
        let anchor =
          ctrls##querySelector (Js.string ".ytp-settings-button")
        in
        (match Js.Opt.to_option anchor with
         | Some a ->
             (match Js.Opt.to_option a##.parentNode with
              | Some parent ->
                  ignore (parent##insertBefore (btn :> Dom.node Js.t)
                            (Js.some (a :> Dom.node Js.t)))
              | None -> Dom.appendChild ctrls btn)
         | None -> Dom.appendChild ctrls btn);
        log "cast button injected")

let schedule_inject () =
  let attempts = ref 0 in
  let timer : Js.Unsafe.any ref = ref (Js.Unsafe.inject Js.null) in
  let cb () =
    Int.incr attempts;
    try_inject ();
    match !attempts >= 20 with
    | true ->
        ignore
          (Js.Unsafe.fun_call (Js.Unsafe.pure_js_expr "clearInterval")
             [| !timer |])
    | false -> ()
  in
  timer :=
    Js.Unsafe.fun_call (Js.Unsafe.pure_js_expr "setInterval")
      [| Js.Unsafe.inject (Js.wrap_callback cb)
       ; Js.Unsafe.inject 500.0 |]

let () =
  log "content script booted";
  schedule_inject ();
  let listener =
    Dom.handler (fun _ ->
      remove_existing "freetube-cast-btn";
      schedule_inject ();
      Js._true)
  in
  ignore
    (Dom.addEventListener
       Dom_html.window
       (Dom.Event.make "yt-navigate-finish")
       listener
       Js._false)
