open! Base

type metadata = {
  title : string;
  mime_type : Mime.t;
  url : string;
  duration_seconds : float option;
  resolution : (int * int) option;
  is_live : bool;
}

let attr name value = (("", name), value)

let tag name attrs children =
  Ezxmlm.make_tag name (attrs, children)

let data s = `Data s

(* Per-MIME DLNA protocolInfo. HLS / DASH manifests can't be byte-range
   seeked, so OP=00 and a streaming-style FLAGS bitmask; progressive
   MP4 / WebM keep OP=01 (Range-seek) plus the conventional
   FLAGS=21700000... that has worked in the wild.
   Live streams add SN_INCREASING (bit 27) to signal growing content. *)
let dlna_attributes_of_mime ~is_live = function
  | Mime.Hls_m3u8 | Mime.Dash_xml ->
      let flags =
        match is_live with
        | true  -> "09700000000000000000000000000000"
        | false -> "01700000000000000000000000000000"
      in
      Printf.sprintf "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=%s" flags
  | Mime.Video_mp4 | Mime.Video_webm ->
      "DLNA.ORG_OP=01;DLNA.ORG_FLAGS=21700000000000000000000000000000"

let format_duration seconds =
  let total_ms = Float.to_int (Float.round_nearest (seconds *. 1000.0)) in
  let h = total_ms / 3_600_000 in
  let m = (total_ms / 60_000) % 60 in
  let s = (total_ms / 1000) % 60 in
  let ms = total_ms % 1000 in
  Printf.sprintf "%d:%02d:%02d.%03d" h m s ms

let generate { title; mime_type; url; duration_seconds; resolution; is_live } =
  let protocol_info =
    String.concat ~sep:""
      [ "http-get:*:"; Mime.to_string mime_type; ":";
        dlna_attributes_of_mime ~is_live mime_type ]
  in
  let upnp_class =
    match is_live with
    | true  -> "object.item.videoItem.videoBroadcast"
    | false -> "object.item.videoItem"
  in
  let res_attrs =
    let duration_attr =
      match duration_seconds with
      | Some d when Float.(d > 0.) -> [ attr "duration" (format_duration d) ]
      | _ -> []
    in
    let resolution_attr =
      match resolution with
      | Some (w, h) when w > 0 && h > 0 ->
          [ attr "resolution" (Printf.sprintf "%dx%d" w h) ]
      | _ -> []
    in
    duration_attr @ resolution_attr
  in
  let didl =
    tag "DIDL-Lite"
      [ (("", "xmlns"), "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/")
      ; (("", "xmlns:dc"), "http://purl.org/dc/elements/1.1/")
      ; (("", "xmlns:upnp"), "urn:schemas-upnp-org:metadata-1-0/upnp/")
      ]
      [ tag "item"
          [ attr "id" "0"; attr "parentID" "0"; attr "restricted" "1" ]
          [ tag "dc:title" [] [ data title ]
          ; tag "upnp:class" [] [ data upnp_class ]
          ; tag "res" ([ attr "protocolInfo" protocol_info ] @ res_attrs) [ data url ]
          ]
      ]
  in
  let buf = Buffer.create 1024 in
  let o = Xmlm.make_output ~decl:false ~indent:None (`Buffer buf) in
  let frag = function
    | `El (t, children) -> `El (t, children)
    | `Data d -> `Data d
  in
  Xmlm.output_doc_tree frag o (None, didl);
  Buffer.contents buf

let%test "format_duration formats H:MM:SS.mmm" =
  String.equal (format_duration 3725.5) "1:02:05.500"

let%test "dlna attributes for HLS use OP=00 streaming flags" =
  String.equal
    (dlna_attributes_of_mime ~is_live:false Mime.Hls_m3u8)
    "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

let%test "dlna attributes for live HLS include SN_INCREASING" =
  String.equal
    (dlna_attributes_of_mime ~is_live:true Mime.Hls_m3u8)
    "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=09700000000000000000000000000000"

let%test "dlna attributes for MP4 use OP=01 range-seek flags" =
  String.equal
    (dlna_attributes_of_mime ~is_live:false Mime.Video_mp4)
    "DLNA.ORG_OP=01;DLNA.ORG_FLAGS=21700000000000000000000000000000"

let%test "generate emits didl-lite structure with HLS protocol info and metadata" =
  let xml =
    generate
      {
        title = "Example & Title";
        mime_type = Mime.Hls_m3u8;
        url = "https://example.test/playlist.m3u8";
        duration_seconds = Some 65.0;
        resolution = Some (1920, 1080);
        is_live = false;
      }
  in
  List.for_all
    [
      "<DIDL-Lite";
      "<dc:title>Example &amp; Title</dc:title>";
      "<upnp:class>object.item.videoItem</upnp:class>";
      "protocolInfo=\"http-get:*:application/vnd.apple.mpegurl:DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\"";
      " duration=\"0:01:05.000\"";
      " resolution=\"1920x1080\"";
      ">https://example.test/playlist.m3u8</res>";
    ]
    ~f:(fun needle -> String.is_substring xml ~substring:needle)

let%test "generate omits res attributes when duration/resolution absent" =
  let xml =
    generate
      {
        title = "Bare";
        mime_type = Mime.Video_mp4;
        url = "http://x/v.mp4";
        duration_seconds = None;
        resolution = None;
        is_live = false;
      }
  in
  (not (String.is_substring xml ~substring:" duration=\""))
  && (not (String.is_substring xml ~substring:" resolution=\""))
  && String.is_substring xml ~substring:">http://x/v.mp4</res>"

let%expect_test "golden DIDL-Lite for HLS with full metadata" =
  let xml =
    generate
      {
        title = "Sample Movie";
        mime_type = Mime.Hls_m3u8;
        url = "http://server/sessions/abc/master.m3u8";
        duration_seconds = Some 3725.5;
        resolution = Some (1920, 1080);
        is_live = false;
      }
  in
  Stdlib.print_endline xml;
  [%expect {| <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="0" restricted="1"><dc:title>Sample Movie</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:application/vnd.apple.mpegurl:DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000" duration="1:02:05.500" resolution="1920x1080">http://server/sessions/abc/master.m3u8</res></item></DIDL-Lite> |}]

let%expect_test "golden DIDL-Lite for progressive MP4 without metadata" =
  let xml =
    generate
      {
        title = "Local";
        mime_type = Mime.Video_mp4;
        url = "http://server/file.mp4";
        duration_seconds = None;
        resolution = None;
        is_live = false;
      }
  in
  Stdlib.print_endline xml;
  [%expect {| <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="0" restricted="1"><dc:title>Local</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=21700000000000000000000000000000">http://server/file.mp4</res></item></DIDL-Lite> |}]

let%expect_test "golden DIDL-Lite for live HLS broadcast" =
  let xml =
    generate
      {
        title = "Live Stream";
        mime_type = Mime.Hls_m3u8;
        url = "http://server/sessions/live1/master.m3u8";
        duration_seconds = None;
        resolution = Some (3840, 2160);
        is_live = true;
      }
  in
  Stdlib.print_endline xml;
  [%expect {| <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="0" restricted="1"><dc:title>Live Stream</dc:title><upnp:class>object.item.videoItem.videoBroadcast</upnp:class><res protocolInfo="http-get:*:application/vnd.apple.mpegurl:DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=09700000000000000000000000000000" resolution="3840x2160">http://server/sessions/live1/master.m3u8</res></item></DIDL-Lite> |}]
