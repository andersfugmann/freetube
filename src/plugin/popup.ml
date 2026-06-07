open! Base
open Js_of_ocaml

(* Popup UI:
   - Main view: server URL + clickable device list (name / type / vendor).
   - Detail view: full device info + config form (prepopulated). *)

let log s = Chrome.log ("freetube/popup: " ^ s)
let document = Dom_html.document

let by_id id = Js.Opt.to_option (document##getElementById (Js.string id))

let set_attr e k v =
  (Js.Unsafe.coerce e : Dom_html.element Js.t)##setAttribute
    (Js.string k) (Js.string v)

let set_html e html =
  Js.Unsafe.set e (Js.string "innerHTML") (Js.string html)

let set_text (e : Dom_html.element Js.t) s =
  e##.textContent := Js.some (Js.string s)

let set_display id v =
  match by_id id with
  | Some e -> Js.Unsafe.set e##.style (Js.string "display") (Js.string v)
  | None -> ()

let get_input_value id =
  match by_id id with
  | None -> ""
  | Some e ->
      let i = Js.Unsafe.coerce e in
      Js.to_string i##.value

let set_input_value id v =
  match by_id id with
  | Some e ->
      let i = Js.Unsafe.coerce e in
      i##.value := Js.string v
  | None -> ()

let on_click id f =
  match by_id id with
  | None -> ()
  | Some e -> e##.onclick := Dom_html.handler (fun _ -> f (); Js._true)

let get_checked id =
  match by_id id with
  | None -> false
  | Some e ->
      let i = Js.Unsafe.coerce e in
      Js.to_bool i##.checked

let set_checked id on =
  match by_id id with
  | None -> ()
  | Some e ->
      let i = Js.Unsafe.coerce e in
      i##.checked := Js.bool on

let get_select id =
  match by_id id with
  | None -> None
  | Some e ->
      let i = Js.Unsafe.coerce e in
      Some (Js.to_string i##.value)

let set_status ?(err = false) s =
  match by_id "status" with
  | Some e ->
      set_text e s;
      set_attr e "class" (if err then "err" else "")
  | None -> ()

let html_escape s =
  String.concat_map s ~f:(function
    | '&' -> "&amp;" | '<' -> "&lt;" | '>' -> "&gt;"
    | '"' -> "&quot;" | '\'' -> "&#39;" | c -> String.make 1 c)

(* ── Codec & vendor enumerations ───────────────────────────────────── *)

let video_all : Codec.Video.t list = [ Av1; Hevc; Vp9; Avc ]
let audio_all : Codec.Audio.t list = [ Opus; Aac; Flac; Vorbis ]
let vendor_all : Api.Vendor.t list = [ Generic; Apple; Samsung; Lg ]

(* ── Device list ───────────────────────────────────────────────────── *)

let device_type_label (d : Device.t) =
  match d.client with
  | Airplay _ -> "AirPlay"
  | Dlna _ -> "DLNA"
  | Url -> "URL"

(* Inline SVG glyphs (currentColor, scale to font size) so the list needs no
   extra image assets. *)
let device_icon (d : Device.t) =
  match d.client with
  | Airplay _ ->
      "<svg class=\"ico\" viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" \
       fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" \
       stroke-linecap=\"round\" stroke-linejoin=\"round\">\
       <path d=\"M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1\"/>\
       <polygon points=\"12 15 17 21 7 21 12 15\"/></svg>"
  | Dlna _ | Url ->
      "<svg class=\"ico\" viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" \
       fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" \
       stroke-linecap=\"round\" stroke-linejoin=\"round\">\
       <path d=\"M2 16.1A5 5 0 0 1 5.9 20M2 12.05A9 9 0 0 1 9.95 20\
       M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6\"/>\
       <line x1=\"2\" y1=\"20\" x2=\"2.01\" y2=\"20\"/></svg>"

let vendor_label (v : Api.Vendor.t) = Api.Vendor.to_string v

let render_device_list ~server ~now (devs : Device.list_response)
    ~(on_select : Device.t -> unit) =
  match by_id "devices" with
  | None -> ()
  | Some container ->
      set_html container "";
      let sorted =
        List.sort devs.devices ~compare:(fun a b ->
          String.compare
            (String.lowercase a.friendly_name)
            (String.lowercase b.friendly_name))
      in
      (match List.is_empty sorted with
       | true ->
           set_html container
             "<div style=\"opacity:0.7;font-size:12px;padding:8px 0;\">\
              No devices found</div>"
       | false ->
           List.iter sorted ~f:(fun (d : Device.t) ->
             let row = Dom_html.createDiv document in
             set_attr row "class" "device-row";
             let name = d.friendly_name in
             let kind = device_type_label d in
             let icon = device_icon d in
             let vendor = vendor_label d.vendor in
             let online = Float.(now -. d.last_seen < 120.) in
             let dot =
               match online with
               | true -> "<span class=\"dot online\"></span>"
               | false -> "<span class=\"dot\"></span>"
             in
             set_html row
               (Printf.sprintf
                  "<div class=\"dleft\">%s\
                   <div><div class=\"name\">%s %s</div>\
                   <div class=\"meta\">%s · %s</div></div></div>\
                   <span class=\"chev\">›</span>"
                  icon (html_escape name) dot kind (html_escape vendor));
             row##.onclick := Dom_html.handler (fun _ ->
               on_select d;
               Js._true);
             Dom.appendChild container row));
      ignore server

(* ── AirPlay pairing dialog ────────────────────────────────────────── *)

let set_pin_status ?(err = false) s =
  match by_id "pin-status" with
  | Some e -> set_text e s; set_attr e "class" (if err then "err" else "")
  | None -> ()

let close_pin_dialog () =
  set_input_value "pin-input" "";
  set_pin_status "";
  set_display "pin-modal" "none"

let open_pin_dialog ~server ~device_id ~friendly =
  set_input_value "pin-input" "";
  set_pin_status "Requesting code…";
  (match by_id "pin-sub" with
   | Some e -> set_text e (Printf.sprintf "Enter the code shown on %s." friendly)
   | None -> ());
  set_display "pin-modal" "flex";
  Api_client.pair_start ~server ~device_id ~k:(function
    | Error e -> set_pin_status ~err:true ("Error: " ^ e)
    | Ok (start : Api.Airplay_pairing.pair_start_response) ->
        let session_id = start.session_id in
        set_pin_status "Enter the code displayed on the device.";
        let submit () =
          match String.strip (get_input_value "pin-input") with
          | "" -> set_pin_status ~err:true "Enter the code first."
          | pin ->
              set_pin_status "Pairing…";
              Api_client.pair_finish ~server ~session_id ~pin ~k:(function
                | Error e -> set_pin_status ~err:true ("Error: " ^ e)
                | Ok _ ->
                    set_pin_status "Paired ✓";
                    close_pin_dialog ())
        in
        on_click "pin-submit" submit;
        on_click "pin-cancel" close_pin_dialog;
        (match by_id "pin-input" with
         | Some e ->
             e##.onkeydown := Dom_html.handler (fun ev ->
               match ev##.keyCode with
               | 13 -> submit (); Js._false
               | _ -> Js._true)
         | None -> ()))

(* ── Device detail view ────────────────────────────────────────────── *)

let render_codec_checks ~prefix ~kind_attr ~all ~to_string ~selected ~equal =
  String.concat ~sep:""
    (List.map all ~f:(fun c ->
       let s = to_string c in
       let on = List.mem selected c ~equal in
       Printf.sprintf
         "<label><input type=\"checkbox\" id=\"%s%s-%s\" \
          data-kind=\"%s\"%s/>%s</label>"
         prefix kind_attr s kind_attr
         (if on then " checked" else "") s))

let render_vendor_options ~(selected : Api.Vendor.t) =
  String.concat ~sep:""
    (List.map vendor_all ~f:(fun v ->
       let s = Api.Vendor.to_string v in
       let sel = if Api.Vendor.equal v selected then " selected" else "" in
       Printf.sprintf "<option value=\"%s\"%s>%s</option>" s sel s))

let info_lines (d : Device.t) =
  let row k v =
    Printf.sprintf "<div><span class=\"k\">%s</span>%s</div>" k (html_escape v)
  in
  match d.client with
  | Airplay a ->
      String.concat
        [ row "kind" "AirPlay"
        ; row "address" (Printf.sprintf "%s:%d" a.address a.port)
        ; row "model" (Option.value a.model ~default:"—")
        ; row "pairing_id" a.pairing_id
        ; row "video" (String.concat ~sep:","
                         (List.map d.video_codecs ~f:Codec.Video.to_string))
        ; row "audio" (String.concat ~sep:","
                         (List.map d.audio_codecs ~f:Codec.Audio.to_string))
        ]
  | Dlna c ->
      String.concat
        [ row "kind" "DLNA"
        ; row "address" c.address
        ; row "manufacturer" c.manufacturer
        ; row "model" c.model_name
        ; row "udn" c.udn
        ; row "control_url" c.control_url
        ; row "video" (String.concat ~sep:","
                         (List.map d.video_codecs ~f:Codec.Video.to_string))
        ; row "audio" (String.concat ~sep:","
                         (List.map d.audio_codecs ~f:Codec.Audio.to_string))
        ]
  | Url ->
      row "kind" "URL"

let device_codecs (d : Device.t) = d.video_codecs, d.audio_codecs

let render_stream_format_options ~(selected : Api.Stream_format.t) =
  let all = [ Api.Stream_format.Hls; Dash ] in
  String.concat ~sep:""
    (List.map all ~f:(fun f ->
       let s = Api.Stream_format.to_string f in
       let label = match f with Hls -> "HLS" | Dash -> "DASH" in
       let sel = if Api.Stream_format.equal f selected then " selected" else "" in
       Printf.sprintf "<option value=\"%s\"%s>%s</option>" s sel label))

let render_detail ~server (d : Device.t) ~back =
  let detail =
    match by_id "view-detail" with
    | Some e -> e
    | None -> failwith "view-detail missing"
  in
  let friendly = d.friendly_name in
  let kind = device_type_label d in
  let prefix = "cfg_" in
  let default_v, default_a = device_codecs d in
  let is_airplay =
    match d.client with Device.Client.Airplay _ -> true | _ -> false
  in
  let pair_button =
    match is_airplay with
    | true -> "<button class=\"pair\" id=\"cfg-pair\">Pair</button>"
    | false -> ""
  in
  set_html detail
    (Printf.sprintf
       "<div class=\"detail-back\">\
          <button class=\"ghost\" id=\"back\">‹ Back</button>\
          <strong style=\"font-size:14px;\">%s</strong>\
          <span style=\"opacity:0.6;font-size:11px;\">(%s)</span>\
        </div>\
        <div class=\"info\">%s</div>\
        <label class=\"lbl\">Video codecs</label>\
        <div class=\"checks\" id=\"vbox\">%s</div>\
        <label class=\"lbl\">Audio codecs</label>\
        <div class=\"checks\" id=\"abox\">%s</div>\
        <label class=\"lbl\" for=\"%svendor\">Vendor</label>\
        <select id=\"%svendor\">%s</select>\
        <label class=\"lbl\" for=\"%sstream_format\">Stream format</label>\
        <select id=\"%sstream_format\">%s</select>\
        <label class=\"lbl\">Options</label>\
        <div><label><input type=\"checkbox\" id=\"%stranscode\"/> \
             Allow transcode</label></div>\
        <div class=\"row\" style=\"margin-top:10px;\">\
          <button id=\"cfg-save\">Save</button>\
          <button class=\"secondary\" id=\"cfg-cancel\">Cancel</button>\
          %s\
          <span id=\"cfg-status\" style=\"font-size:11px;color:#8c8;\"></span>\
        </div>"
       (html_escape friendly) kind
       (info_lines d)
       (render_codec_checks ~prefix ~kind_attr:"v" ~all:video_all
          ~to_string:Codec.Video.to_string ~selected:default_v
          ~equal:Codec.Video.equal)
       (render_codec_checks ~prefix ~kind_attr:"a" ~all:audio_all
          ~to_string:Codec.Audio.to_string ~selected:default_a
          ~equal:Codec.Audio.equal)
       prefix prefix (render_vendor_options ~selected:d.vendor)
       prefix prefix (render_stream_format_options ~selected:d.stream_format)
       prefix pair_button);
  set_display "view-main" "none";
  set_display "view-detail" "block";
  (match is_airplay with
   | true ->
       on_click "cfg-pair" (fun () ->
         open_pin_dialog ~server ~device_id:d.id ~friendly)
   | false -> ());

  let collect_video () =
    List.filter video_all ~f:(fun c ->
      get_checked (prefix ^ "v-" ^ Codec.Video.to_string c))
  in
  let collect_audio () =
    List.filter audio_all ~f:(fun c ->
      get_checked (prefix ^ "a-" ^ Codec.Audio.to_string c))
  in
  let prepop (cfg : Api.Config_device.t) =
    List.iter video_all ~f:(fun c ->
      set_checked (prefix ^ "v-" ^ Codec.Video.to_string c)
        (List.mem cfg.video_codecs c ~equal:Codec.Video.equal));
    List.iter audio_all ~f:(fun c ->
      set_checked (prefix ^ "a-" ^ Codec.Audio.to_string c)
        (List.mem cfg.audio_codecs c ~equal:Codec.Audio.equal));
    set_input_value (prefix ^ "vendor") (Api.Vendor.to_string cfg.vendor);
    set_input_value (prefix ^ "stream_format") (Api.Stream_format.to_string cfg.stream_format);
    set_checked (prefix ^ "transcode") cfg.transcode
  in
  Api_client.get_device_config ~server ~id:d.id ~k:(function
    | Error e -> log ("config load failed: " ^ e)
    | Ok None -> ()
    | Ok (Some cfg) -> prepop cfg);

  on_click "back" back;
  on_click "cfg-cancel" back;
  on_click "cfg-save" (fun () ->
    let vendor =
      match
        Option.bind (get_select (prefix ^ "vendor")) ~f:(fun s ->
          List.find vendor_all ~f:(fun v ->
            String.equal (Api.Vendor.to_string v) s))
      with
      | Some v -> v
      | None -> d.vendor
    in
    let stream_format =
      match get_select (prefix ^ "stream_format") with
      | Some "dash" -> Api.Stream_format.Dash
      | _ -> Api.Stream_format.Hls
    in
    let cfg : Api.Config_device.t =
      { id = d.id
      ; friendly_name = friendly
      ; video_codecs = collect_video ()
      ; audio_codecs = collect_audio ()
      ; vendor
      ; is_static = false
      ; kind = None
      ; address = None
      ; port = None
      ; control_url = None
      ; transcode = get_checked (prefix ^ "transcode")
      ; stream_format
      }
    in
    (match by_id "cfg-status" with
     | Some e -> set_text e "Saving..."
     | None -> ());
    Api_client.put_device_config ~server ~id:d.id ~cfg ~k:(function
      | Ok () -> back ()
      | Error e ->
          (match by_id "cfg-status" with
           | Some el -> set_text el ("Error: " ^ e)
           | None -> ())))

(* ── Settings view ──────────────────────────────────────────────────── *)

let number_field ~id ~label ~value =
  Printf.sprintf
    "<label class=\"lbl\" for=\"%s\">%s</label>\
     <input type=\"number\" id=\"%s\" value=\"%s\" />"
    id label id value

let text_field ~id ~label ~value =
  Printf.sprintf
    "<label class=\"lbl\" for=\"%s\">%s</label>\
     <input type=\"text\" id=\"%s\" value=\"%s\" />"
    id label id value

let select_field ~id ~label ~options ~selected =
  let opts = String.concat ~sep:""
    (List.map options ~f:(fun (v, lbl) ->
       let sel = match String.equal v selected with true -> " selected" | false -> "" in
       Printf.sprintf "<option value=\"%s\"%s>%s</option>" v sel lbl))
  in
  Printf.sprintf
    "<label class=\"lbl\" for=\"%s\">%s</label>\
     <select id=\"%s\">%s</select>"
    id label id opts

let checkbox_field ~id ~label ~checked =
  Printf.sprintf
    "<div><label><input type=\"checkbox\" id=\"%s\"%s /> %s</label></div>"
    id (match checked with true -> " checked" | false -> "") label

let ip_version_string = function
  | `V4 -> "v4"
  | `V6 -> "v6"

let ip_version_of_string = function
  | "v6" -> `V6
  | _ -> `V4

let render_settings ~server ~back =
  let container =
    match by_id "view-settings" with
    | Some e -> e
    | None -> failwith "view-settings missing"
  in
  set_html container "<div style=\"opacity:0.6\">Loading…</div>";
  set_display "view-main" "none";
  set_display "view-detail" "none";
  set_display "view-settings" "block";
  Api_client.get_config ~server ~k:(function
    | Error e ->
      set_html container
        (Printf.sprintf "<div class=\"err\">%s</div>" (html_escape e))
    | Ok (cfg : Config.t) ->
      set_html container
        (String.concat
           [ "<div class=\"detail-back\">\
                <button class=\"ghost\" id=\"set-back\">‹ Back</button>\
                <strong style=\"font-size:14px;\">Settings</strong>\
              </div>"
           ; "<div class=\"section\"><div class=\"section-title\">Streaming</div>"
           ; number_field ~id:"s-prefetch" ~label:"Prefetch count"
               ~value:(Int.to_string cfg.streaming.prefetch_count)
           ; number_field ~id:"s-cache" ~label:"Cache capacity"
               ~value:(Int.to_string cfg.streaming.cache_capacity)
           ; number_field ~id:"s-stale" ~label:"Stale threshold (sec)"
               ~value:(Printf.sprintf "%.1f" cfg.streaming.segment_stale_threshold_seconds)
           ; number_field ~id:"s-window" ~label:"Live window (sec)"
               ~value:(Int.to_string cfg.streaming.live_window_seconds)
           ; "</div>"
           ; "<div class=\"section\"><div class=\"section-title\">Network</div>"
           ; number_field ~id:"n-conn" ~label:"Max connections per host"
               ~value:(Int.to_string cfg.network.max_connections_per_host)
           ; number_field ~id:"n-redir" ~label:"Max redirects"
               ~value:(Int.to_string cfg.network.max_redirects)
           ; select_field ~id:"n-ip" ~label:"Preferred IP version"
               ~options:[("v4", "IPv4"); ("v6", "IPv6")]
               ~selected:(ip_version_string cfg.network.prefer_ip_version)
           ; number_field ~id:"n-chunk" ~label:"File chunk size (bytes)"
               ~value:(Int.to_string cfg.network.file_chunk_size)
           ; checkbox_field ~id:"n-ipv6" ~label:"Force IPv6 for yt-dlp"
               ~checked:cfg.network.yt_dlp_force_ipv6
           ; "</div>"
           ; "<div class=\"section\"><div class=\"section-title\">Video</div>"
           ; number_field ~id:"v-width" ~label:"Max width"
               ~value:(Int.to_string cfg.video.max_width)
           ; number_field ~id:"v-height" ~label:"Max height"
               ~value:(Int.to_string cfg.video.max_height)
           ; "</div>"
           ; "<div class=\"section\"><div class=\"section-title\">Discovery</div>"
           ; number_field ~id:"d-timeout" ~label:"Scan timeout (sec)"
               ~value:(Printf.sprintf "%.1f" cfg.discovery.scan_timeout_seconds)
           ; number_field ~id:"d-airplay" ~label:"AirPlay interval (sec)"
               ~value:(Printf.sprintf "%.1f" cfg.discovery.airplay_interval_seconds)
           ; number_field ~id:"d-dlna" ~label:"DLNA interval (sec)"
               ~value:(Printf.sprintf "%.1f" cfg.discovery.dlna_interval_seconds)
           ; "</div>"
           ; "<div class=\"section\"><div class=\"section-title\">General</div>"
           ; checkbox_field ~id:"g-transcode" ~label:"Allow transcode"
               ~checked:cfg.transcode
           ; text_field ~id:"g-gpu" ~label:"GPU device (blank = auto)"
               ~value:(Option.value cfg.gpu_device ~default:"")
           ; "</div>"
           ; "<div class=\"row\" style=\"margin-top:10px;\">\
                <button id=\"set-save\">Save</button>\
                <button class=\"secondary\" id=\"set-cancel\">Cancel</button>\
                <span id=\"set-status\" style=\"font-size:11px;color:#8c8;\"></span>\
              </div>"
           ]);
      on_click "set-back" back;
      on_click "set-cancel" back;
      on_click "set-save" (fun () ->
        let int_or id default = Option.value (Int.of_string_opt (get_input_value id)) ~default in
        let float_or id default = Option.value (Float.of_string_opt (get_input_value id)) ~default in
        let config : Config.t = {
          listen_port = cfg.listen_port;
          session_ttl_seconds = cfg.session_ttl_seconds;
          ntp_port = cfg.ntp_port;
          transcode = get_checked "g-transcode";
          gpu_device = (match get_input_value "g-gpu" with "" -> None | s -> Some s);
          streaming = {
            prefetch_count = int_or "s-prefetch" cfg.streaming.prefetch_count;
            cache_capacity = int_or "s-cache" cfg.streaming.cache_capacity;
            segment_stale_threshold_seconds = float_or "s-stale" cfg.streaming.segment_stale_threshold_seconds;
            live_window_seconds = int_or "s-window" cfg.streaming.live_window_seconds;
            default_segment_duration_us = cfg.streaming.default_segment_duration_us;
          };
          network = {
            max_connections_per_host = int_or "n-conn" cfg.network.max_connections_per_host;
            max_redirects = int_or "n-redir" cfg.network.max_redirects;
            prefer_ip_version = ip_version_of_string (Option.value (get_select "n-ip") ~default:"v4");
            file_chunk_size = int_or "n-chunk" cfg.network.file_chunk_size;
            yt_dlp_force_ipv6 = get_checked "n-ipv6";
          };
          video = {
            max_width = int_or "v-width" cfg.video.max_width;
            max_height = int_or "v-height" cfg.video.max_height;
          };
          discovery = {
            scan_timeout_seconds = float_or "d-timeout" cfg.discovery.scan_timeout_seconds;
            airplay_interval_seconds = float_or "d-airplay" cfg.discovery.airplay_interval_seconds;
            dlna_interval_seconds = float_or "d-dlna" cfg.discovery.dlna_interval_seconds;
          };
        } in
        (match by_id "set-status" with
         | Some e -> set_text e "Saving…"
         | None -> ());
        Api_client.put_config ~server ~config ~k:(function
          | Ok _ ->
            (match by_id "set-status" with
             | Some e -> set_text e "Saved ✓"
             | None -> ())
          | Error msg ->
            (match by_id "set-status" with
             | Some el -> set_text el ("Error: " ^ msg)
             | None -> ()))))

(* ── Top-level orchestration ───────────────────────────────────────── *)

let rec back_to_main ~server () =
  set_display "view-detail" "none";
  set_display "view-settings" "none";
  set_display "view-main" "block";
  load_devices ~server

and load_devices ~server =
  set_status "Loading devices…";
  Api_client.get_devices ~server ~k:(function
    | Error e -> set_status ~err:true ("Error: " ^ e)
    | Ok (r : Device.list_response) ->
        let now = Js.to_float (new%js Js.date_now)##getTime /. 1000. in
        set_status
          (Printf.sprintf "%d device(s)" (List.length r.devices));
        render_device_list ~server ~now r ~on_select:(fun d ->
          render_detail ~server d ~back:(back_to_main ~server)))

let () =
  log "popup booted";
  Api_client.load_server ~k:(fun s ->
    set_input_value "server" s;
    load_devices ~server:s);
  on_click "save" (fun () ->
    let v = get_input_value "server" in
    Api_client.save_server v;
    set_status "Saved";
    load_devices ~server:v);
  on_click "reload" (fun () ->
    let v = get_input_value "server" in
    load_devices ~server:v);
  on_click "settings" (fun () ->
    let server = get_input_value "server" in
    render_settings ~server ~back:(back_to_main ~server))
