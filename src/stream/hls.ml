open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HLS manifest generation" Stdlib.__MODULE__)
let _ = Log.debug

let escape_attribute value =
  String.map value ~f:(function
    | '"' -> '\''
    | '\n' | '\r' -> ' '
    | char -> char)

module Stream = Youtube.Video_info.Stream

(** Per-tag gating decisions resolved upstream from the destination
    device vendor. See plan §C4 for the matrix. *)
type profile = {
  independent_segments : bool;
  playlist_type        : bool;
  session_data         : bool;
  start_offset         : bool;
  iframe_stream        : bool;
}

let generic_profile = {
  independent_segments = true;
  playlist_type        = true;
  session_data         = true;
  start_offset         = true;
  iframe_stream        = true;
}

let hdcp_level dr =
  match dr with
  | Codec.Dynamic_range.Sdr -> None
  | Hlg | Hdr10 | Hdr10_plus | Dolby_vision -> Some "TYPE-1"

let dynamic_range_string : Codec.Dynamic_range.t -> string = function
  | Sdr -> "SDR"
  | Hlg -> "HLG"
  | Hdr10 | Hdr10_plus | Dolby_vision -> "PQ"

let video_bitrate_bps (s : Stream.t) =
  let kbps =
    match s.vbr with
    | Some v -> v
    | None -> Option.value s.tbr ~default:0.0
  in
  Float.to_int (kbps *. 1000.0)

let audio_bitrate_bps (s : Stream.t) =
  Float.to_int (Option.value s.abr ~default:0.0 *. 1000.0)

(** Apple §1.10 recommends [hvc1] in the CODECS attribute (parameter
    sets carried in the sample entry). YouTube's metadata sometimes
    advertises [hev1.*]; rewrite to [hvc1.*] for the CODECS string
    only — the fMP4 sample-entry box is not touched. *)
let normalize_codec s =
  match String.is_prefix s ~prefix:"hev1." with
  | true  -> "hvc1." ^ String.drop_prefix s 5
  | false -> s

let secs_of_usec usec = Float.of_int usec /. 1_000_000.

let frame_rate fps = Stdlib.Printf.sprintf "%.3f" fps
let extinf_duration secs = Stdlib.Printf.sprintf "%.3f" secs

let path base_url suffix = base_url ^ "/" ^ suffix

let target_duration segments =
  let max_d =
    Array.fold segments ~init:0. ~f:(fun acc (s : Producer.Segment_info.t) ->
      Float.max acc (secs_of_usec s.length_usec))
  in
  match Float.(max_d <= 0.) with
  | true -> 1
  | false -> Stdlib.int_of_float (Stdlib.ceil max_d)

let average_bandwidth_bps segments =
  let total_bytes, total_usec =
    Array.fold segments ~init:(0, 0)
      ~f:(fun (b, u) (s : Producer.Segment_info.t) ->
        b + s.byte_length, u + s.length_usec)
  in
  match total_usec with
  | 0 -> 0
  | _ -> (total_bytes * 8 * 1_000_000) / total_usec

let segment_lines ~is_live _rendition ext segments =
  Array.to_list segments
  |> List.mapi ~f:(fun index (s : Producer.Segment_info.t) ->
    let dur = secs_of_usec s.length_usec in
    let seg_id =
      match is_live with
      | true -> s.start_usec / s.length_usec
      | false -> index
    in
    [ Stdlib.Printf.sprintf "#EXTINF:%s," (extinf_duration dur)
    ; Printf.sprintf "seg/%d.%s" seg_id ext
    ])
  |> List.concat

let format_iso8601 walltime_ms =
  let span = Ptime.Span.of_int_s (walltime_ms / 1000) in
  let t = Ptime.of_span span |> Option.value_exn ~message:"invalid walltime" in
  let millis = walltime_ms % 1000 in
  let (y, m, d), ((hh, mm, ss), _tz) = Ptime.to_date_time t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03d+00:00" y m d hh mm ss millis

let media ?(profile = generic_profile) ?(media_sequence = 0) ?program_date_time
      ~base_url:_ ~rendition ~ext ~is_live segments =
  let init_uri = Printf.sprintf "init.%s" ext in
  let header =
    [ "#EXTM3U"
    ; "#EXT-X-VERSION:7"
    ; Stdlib.Printf.sprintf "#EXT-X-TARGETDURATION:%d" (target_duration segments)
    ; Stdlib.Printf.sprintf "#EXT-X-MEDIA-SEQUENCE:%d" media_sequence
    ]
  in
  let map_line = Stdlib.Printf.sprintf "#EXT-X-MAP:URI=\"%s\"" init_uri in
  let body_prefix =
    match is_live, profile.start_offset, profile.playlist_type with
    | true,  true,  _     -> [ map_line; "#EXT-X-START:TIME-OFFSET=-60,PRECISE=YES" ]
    | true,  false, _     -> [ map_line ]
    | false, _,     true  -> [ "#EXT-X-PLAYLIST-TYPE:VOD"; map_line ]
    | false, _,     false -> [ map_line ]
  in
  let pdt_line =
    match program_date_time with
    | Some wt_ms -> [ Stdlib.Printf.sprintf "#EXT-X-PROGRAM-DATE-TIME:%s" (format_iso8601 wt_ms) ]
    | None -> []
  in
  let ending =
    match is_live with
    | true -> []
    | false -> [ "#EXT-X-ENDLIST" ]
  in
  String.concat ~sep:"\n"
    (header @ body_prefix @ pdt_line @ segment_lines ~is_live rendition ext segments @ ending)
  ^ "\n"

let master ?(profile = generic_profile) ?iframe_stream ~title
    ~(video : Stream.t) ~(audio : Stream.t)
    ~video_rfc6381 ~audio_rfc6381
    ~average_bandwidth_bps:avg_bw () =
  let bandwidth = video_bitrate_bps video + audio_bitrate_bps audio in
  let width = Option.value video.width ~default:0 in
  let height = Option.value video.height ~default:0 in
  let fps = Option.value video.fps ~default:0.0 in
  let channels = Option.value audio.audio_channels ~default:2 in
  let dr = Option.value video.dynamic_range ~default:Codec.Dynamic_range.Sdr in
  let header =
    [ "#EXTM3U"
    ; "#EXT-X-VERSION:7"
    ]
  in
  let independent =
    match profile.independent_segments with
    | true -> [ "#EXT-X-INDEPENDENT-SEGMENTS" ]
    | false -> []
  in
  let session_data =
    match profile.session_data with
    | true ->
        [ Stdlib.Printf.sprintf
            "#EXT-X-SESSION-DATA:DATA-ID=\"com.apple.hls.title\",VALUE=\"%s\""
            (escape_attribute title)
        ]
    | false -> []
  in
  let media_audio =
    let name =
      let non_empty = function Some s when not (String.is_empty s) -> Some s | _ -> None in
      List.find_map [ non_empty audio.format_note; non_empty audio.language ] ~f:Fn.id
      |> Option.value ~default:audio.format_id
      |> escape_attribute
    in
    Stdlib.Printf.sprintf
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"%s\",LANGUAGE=\"und\",DEFAULT=YES,AUTOSELECT=YES,URI=\"%s\",CHANNELS=\"%d\""
      name
      "audio/media.m3u8"
      channels
  in
  let stream_inf =
    let hdcp_attr =
      match hdcp_level dr with
      | Some level -> Printf.sprintf ",HDCP-LEVEL=%s" level
      | None -> ""
    in
    Stdlib.Printf.sprintf
      "#EXT-X-STREAM-INF:BANDWIDTH=%d,AVERAGE-BANDWIDTH=%d,RESOLUTION=%dx%d,CODECS=\"%s,%s\",FRAME-RATE=%s,AUDIO=\"audio\",CLOSED-CAPTIONS=NONE,VIDEO-RANGE=%s%s"
      bandwidth
      avg_bw
      width
      height
      (normalize_codec video_rfc6381)
      (normalize_codec audio_rfc6381)
      (frame_rate fps)
      (dynamic_range_string dr)
      hdcp_attr
  in
  let iframe_stream_inf =
    match profile.iframe_stream, iframe_stream with
    | true, Some ifs ->
      let iw = Iframe_stream.thumb_width ifs in
      let ih = Iframe_stream.thumb_height ifs in
      let bw = (iw * ih * 8) / 2 in
      [ ""; Stdlib.Printf.sprintf
          "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%dx%d,CODECS=\"avc1.42c00d\",URI=\"iframe/media.m3u8\",VIDEO-RANGE=%s"
          bw iw ih (dynamic_range_string Codec.Dynamic_range.Sdr) ]
    | _ -> []
  in
  String.concat ~sep:"\n"
    (header @ independent @ session_data @ [ ""; media_audio; ""; stream_inf;
                                             "video/media.m3u8" ] @ iframe_stream_inf)
  ^ "\n"

let iframe_media iframe =
  let count = Iframe_stream.frame_count iframe in
  let dur = Iframe_stream.frame_duration_secs iframe in
  let target_duration = Stdlib.int_of_float (Stdlib.ceil dur) in
  let init_end = iframe.Iframe_stream.init_end in
  let header =
    [ "#EXTM3U"
    ; "#EXT-X-VERSION:7"
    ; Stdlib.Printf.sprintf "#EXT-X-TARGETDURATION:%d" target_duration
    ; "#EXT-X-PLAYLIST-TYPE:VOD"
    ; "#EXT-X-I-FRAMES-ONLY"
    ; Stdlib.Printf.sprintf "#EXT-X-MAP:URI=\"stream.mp4\",BYTERANGE=\"%d@0\"" init_end
    ]
  in
  let segments =
    List.init count ~f:(fun i ->
      let (offset, len) = iframe.frame_ranges.(i) in
      [ Stdlib.Printf.sprintf "#EXTINF:%s," (extinf_duration dur)
      ; Stdlib.Printf.sprintf "#EXT-X-BYTERANGE:%d@%d" len offset
      ; "stream.mp4" ])
    |> List.concat
  in
  String.concat ~sep:"\n" (header @ segments @ [ "#EXT-X-ENDLIST" ]) ^ "\n"

let sample_video : Stream.t = {
  format_id = "v";
  format_note = None;
  url = "";
  ext = Youtube.Video_info.Container.Mp4;
  vcodec = Some (Codec.Video.Avc, "avc1.640028");
  acodec = None;
  width = Some 1920; height = Some 1080;
  fps = Some 30.;
  tbr = Some 4500.0;
  vbr = Some 4500.0;
  abr = None;
  asr_ = None;
  audio_channels = None;
    dynamic_range = Some Codec.Dynamic_range.Sdr;
  protocol = Youtube.Video_info.Protocol_kind.Https;
  fragment_base_url = None;
  fragments = [];
  http_headers = [];
  language = None;
  language_preference = -1;
  rows = None;
  columns = None;
}

let sample_audio : Stream.t = {
  format_id = "a";
  format_note = Some "medium";
  url = "";
  ext = Youtube.Video_info.Container.Mp4;
  vcodec = None;
  acodec = Some (Codec.Audio.Aac, "mp4a.40.2");
  width = None; height = None; fps = None; tbr = None; vbr = None;
  abr = Some 128.0;
  asr_ = Some 48_000;
  audio_channels = Some 2;
  dynamic_range = None;
  protocol = Youtube.Video_info.Protocol_kind.Https;
  fragment_base_url = None;
  fragments = [];
  http_headers = [];
  language = Some "en-us";
  language_preference = 2;
  rows = None;
  columns = None;
}

let sample_segments : Producer.Segment_info.t array = [|
  { start_usec = 0;        length_usec = 4_100_000; byte_length = 100 };
  { start_usec = 4_100_000; length_usec = 4_000_000; byte_length = 100 };
  { start_usec = 8_100_000; length_usec = 3_200_000; byte_length = 100 };
|]

let%expect_test "master playlist contains required tags" =
  let playlist =
    master ~title:"Test Title"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.Printf.printf
    "%b %b %b %b %b\n"
    (String.is_substring playlist ~substring:"#EXTM3U")
    (String.is_substring playlist ~substring:"#EXT-X-VERSION:7")
    (String.is_substring playlist ~substring:"FRAME-RATE=30.000")
    (String.is_substring playlist ~substring:"AVERAGE-BANDWIDTH=4200000")
    (String.is_substring playlist ~substring:"LANGUAGE=\"und\"");
  [%expect {| true true true true true |}]

let%expect_test "master playlist gating: Samsung-style profile drops advisory tags" =
  let samsung = {
    independent_segments = false;
    playlist_type        = false;
    session_data         = false;
    start_offset         = false;
    iframe_stream        = false;
  } in
  let playlist =
    master ~profile:samsung ~title:"Test Title"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.Printf.printf "ind=%b sess=%b\n"
    (String.is_substring playlist ~substring:"INDEPENDENT-SEGMENTS")
    (String.is_substring playlist ~substring:"SESSION-DATA");
  [%expect {| ind=false sess=false |}]

let%expect_test "media playlist gating: Samsung drops PLAYLIST-TYPE" =
  let samsung = {
    independent_segments = false;
    playlist_type        = false;
    session_data         = false;
    start_offset         = false;
    iframe_stream        = false;
  } in
  let playlist =
    media ~profile:samsung
      ~base_url:"/session/abc123" ~rendition:"video" ~ext:"mp4"
      ~is_live:false sample_segments
  in
  Stdlib.Printf.printf "pt=%b end=%b\n"
    (String.is_substring playlist ~substring:"PLAYLIST-TYPE")
    (String.is_substring playlist ~substring:"#EXT-X-ENDLIST");
  [%expect {| pt=false end=true |}]

let%expect_test "vod media playlist ends and includes each segment" =
  let playlist =
    media ~base_url:"/session/abc123" ~rendition:"video" ~ext:"webm" ~is_live:false sample_segments
  in
  let segment_count =
    playlist
    |> String.split_lines
    |> List.count ~f:(String.is_prefix ~prefix:"seg/")
  in
  Stdlib.Printf.printf
    "%b %d\n"
    (String.is_substring playlist ~substring:"#EXT-X-ENDLIST")
    segment_count;
  [%expect {| true 3 |}]

let%expect_test "target duration uses ceiling of max segment duration" =
  let line =
    media ~base_url:"/session/abc123" ~rendition:"video" ~ext:"webm" ~is_live:false sample_segments
    |> String.split_lines
    |> List.find_exn ~f:(String.is_prefix ~prefix:"#EXT-X-TARGETDURATION:")
  in
  Stdlib.Printf.printf "%s\n" line;
  [%expect {| #EXT-X-TARGETDURATION:5 |}]

let%expect_test "normalize_codec rewrites hev1 to hvc1 but leaves others" =
  List.iter [ "hev1.1.6.L153.B0"; "hvc1.1.6.L153.B0"; "avc1.640028"; "vp09.00.10.08"; "opus" ]
    ~f:(fun s -> Stdlib.Printf.printf "%s -> %s\n" s (normalize_codec s));
  [%expect {|
    hev1.1.6.L153.B0 -> hvc1.1.6.L153.B0
    hvc1.1.6.L153.B0 -> hvc1.1.6.L153.B0
    avc1.640028 -> avc1.640028
    vp09.00.10.08 -> vp09.00.10.08
    opus -> opus
    |}]

let%expect_test "master playlist: HDR variant emits HDCP-LEVEL=TYPE-1" =
  let hdr_video = { sample_video with dynamic_range = Some Codec.Dynamic_range.Hdr10 } in
  let playlist =
    master ~title:"Test Title"
      ~video:hdr_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.Printf.printf "%b\n"
    (String.is_substring playlist ~substring:"HDCP-LEVEL=TYPE-1");
  [%expect {| true |}]

let%expect_test "master playlist: SDR variant omits HDCP-LEVEL" =
  let playlist =
    master ~title:"Test Title"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.Printf.printf "%b\n"
    (String.is_substring playlist ~substring:"HDCP-LEVEL");
  [%expect {| false |}]

let%expect_test "golden master playlist: Apple/Generic profile" =
  let playlist =
    master ~profile:generic_profile ~title:"abc"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.print_string playlist;
  [%expect {|
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="abc"

    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="medium",LANGUAGE="und",DEFAULT=YES,AUTOSELECT=YES,URI="audio/media.m3u8",CHANNELS="2"

    #EXT-X-STREAM-INF:BANDWIDTH=4628000,AVERAGE-BANDWIDTH=4200000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000,AUDIO="audio",CLOSED-CAPTIONS=NONE,VIDEO-RANGE=SDR
    video/media.m3u8
    |}]

let%expect_test "golden master playlist: Samsung profile" =
  let samsung = {
    independent_segments = false; playlist_type = false;
    session_data = false; start_offset = false;
    iframe_stream = false;
  } in
  let playlist =
    master ~profile:samsung ~title:"abc"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.print_string playlist;
  [%expect {|
    #EXTM3U
    #EXT-X-VERSION:7

    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="medium",LANGUAGE="und",DEFAULT=YES,AUTOSELECT=YES,URI="audio/media.m3u8",CHANNELS="2"

    #EXT-X-STREAM-INF:BANDWIDTH=4628000,AVERAGE-BANDWIDTH=4200000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000,AUDIO="audio",CLOSED-CAPTIONS=NONE,VIDEO-RANGE=SDR
    video/media.m3u8
    |}]

let%expect_test "golden master playlist: Lg profile drops SESSION-DATA only" =
  let lg = {
    independent_segments = true; playlist_type = true;
    session_data = false; start_offset = true;
    iframe_stream = false;
  } in
  let playlist =
    master ~profile:lg ~title:"abc"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.print_string playlist;
  [%expect {|
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-INDEPENDENT-SEGMENTS

    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="medium",LANGUAGE="und",DEFAULT=YES,AUTOSELECT=YES,URI="audio/media.m3u8",CHANNELS="2"

    #EXT-X-STREAM-INF:BANDWIDTH=4628000,AVERAGE-BANDWIDTH=4200000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000,AUDIO="audio",CLOSED-CAPTIONS=NONE,VIDEO-RANGE=SDR
    video/media.m3u8
    |}]

let%expect_test "golden media playlist: VOD generic profile" =
  let playlist =
    media ~base_url:"/sessions/abc" ~rendition:"video" ~ext:"mp4"
      ~is_live:false sample_segments
  in
  Stdlib.print_string playlist;
  [%expect {|
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:5
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:4.100,
    seg/0.mp4
    #EXTINF:4.000,
    seg/1.mp4
    #EXTINF:3.200,
    seg/2.mp4
    #EXT-X-ENDLIST
    |}]

let%expect_test "golden media playlist: Samsung profile drops PLAYLIST-TYPE" =
  let samsung = {
    independent_segments = false; playlist_type = false;
    session_data = false; start_offset = false;
    iframe_stream = false;
  } in
  let playlist =
    media ~profile:samsung ~base_url:"/sessions/abc" ~rendition:"video"
      ~ext:"mp4" ~is_live:false sample_segments
  in
  Stdlib.print_string playlist;
  [%expect {|
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:5
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:4.100,
    seg/0.mp4
    #EXTINF:4.000,
    seg/1.mp4
    #EXTINF:3.200,
    seg/2.mp4
    #EXT-X-ENDLIST
    |}]

let%expect_test "average_bandwidth_bps computes from segment totals" =
  let segs : Producer.Segment_info.t array = [|
    { start_usec = 0;         length_usec = 2_000_000; byte_length = 250_000 };
    { start_usec = 2_000_000; length_usec = 2_000_000; byte_length = 250_000 };
  |] in
  Stdlib.Printf.printf "%d\n" (average_bandwidth_bps segs);
  [%expect {| 1000000 |}]

(** Audio/video segment-duration parity check. Apple §6.7 and LG webOS
    require matching segment boundaries; drift hurts every vendor. *)
let segment_parity_violations ~tolerance_usec ~video ~audio =
  let nv = Array.length video and na = Array.length audio in
  let count_mismatch =
    match nv = na with
    | true -> []
    | false -> [ Printf.sprintf "segment count mismatch: video=%d audio=%d" nv na ]
  in
  let n = Int.min nv na in
  let per_index =
    List.init n ~f:(fun i ->
      let v = (video.(i) : Producer.Segment_info.t).length_usec in
      let a = (audio.(i) : Producer.Segment_info.t).length_usec in
      let drift = Int.abs (v - a) in
      match drift > tolerance_usec with
      | true -> Some (Printf.sprintf "segment %d: drift=%dus video=%d audio=%d"
                        i drift v a)
      | false -> None)
    |> List.filter_opt
  in
  count_mismatch @ per_index

let%expect_test "segment_parity_violations: equal arrays ok" =
  let segs : Producer.Segment_info.t array = [|
    { start_usec = 0;         length_usec = 4_000_000; byte_length = 100 };
    { start_usec = 4_000_000; length_usec = 4_000_000; byte_length = 100 };
  |] in
  let violations =
    segment_parity_violations ~tolerance_usec:200_000 ~video:segs ~audio:segs
  in
  Stdlib.Printf.printf "%d\n" (List.length violations);
  [%expect {| 0 |}]

let%expect_test "segment_parity_violations: drift beyond tolerance reported" =
  let video : Producer.Segment_info.t array = [|
    { start_usec = 0; length_usec = 4_000_000; byte_length = 100 };
    { start_usec = 4_000_000; length_usec = 4_000_000; byte_length = 100 };
  |] in
  let audio : Producer.Segment_info.t array = [|
    { start_usec = 0; length_usec = 4_000_000; byte_length = 100 };
    { start_usec = 4_000_000; length_usec = 4_400_000; byte_length = 100 };
  |] in
  let violations =
    segment_parity_violations ~tolerance_usec:200_000 ~video ~audio
  in
  List.iter violations ~f:Stdlib.print_endline;
  [%expect {| segment 1: drift=400000us video=4000000 audio=4400000 |}]

let%expect_test "segment_parity_violations: count mismatch reported" =
  let video : Producer.Segment_info.t array = [|
    { start_usec = 0; length_usec = 4_000_000; byte_length = 100 };
  |] in
  let audio : Producer.Segment_info.t array = [|
    { start_usec = 0;         length_usec = 4_000_000; byte_length = 100 };
    { start_usec = 4_000_000; length_usec = 4_000_000; byte_length = 100 };
  |] in
  let violations =
    segment_parity_violations ~tolerance_usec:200_000 ~video ~audio
  in
  List.iter violations ~f:Stdlib.print_endline;
  [%expect {| segment count mismatch: video=1 audio=2 |}]

let%expect_test "iframe_media: golden I-frame-only playlist" =
  let ifs : Iframe_stream.t = {
    data = String.make 3774 '\x00';
    init_end = 774;
    frame_ranges = [| (774, 1000); (1774, 1000); (2774, 1000) |];
    thumb_width = 159;
    thumb_height = 90;
    frame_duration_secs = 2.0;
  } in
  let playlist = iframe_media ifs in
  Stdlib.print_string playlist;
  [%expect {|
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:2
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-I-FRAMES-ONLY
    #EXT-X-MAP:URI="stream.mp4",BYTERANGE="774@0"
    #EXTINF:2.000,
    #EXT-X-BYTERANGE:1000@774
    stream.mp4
    #EXTINF:2.000,
    #EXT-X-BYTERANGE:1000@1774
    stream.mp4
    #EXTINF:2.000,
    #EXT-X-BYTERANGE:1000@2774
    stream.mp4
    #EXT-X-ENDLIST
    |}]

let%expect_test "master playlist: I-FRAME-STREAM-INF emitted for generic profile" =
  let ifs : Iframe_stream.t = {
    data = String.make 5774 '\x00';
    init_end = 774;
    frame_ranges = Array.init 5 ~f:(fun i -> (774 + i * 1000, 1000));
    thumb_width = 159;
    thumb_height = 90;
    frame_duration_secs = 2.0;
  } in
  let playlist =
    master ~profile:generic_profile ~iframe_stream:ifs ~title:"Test"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.Printf.printf "%b\n"
    (String.is_substring playlist ~substring:"#EXT-X-I-FRAME-STREAM-INF:");
  Stdlib.Printf.printf "%b\n"
    (String.is_substring playlist ~substring:"URI=\"iframe/media.m3u8\"");
  [%expect {|
    true
    true
    |}]

let%expect_test "master playlist: I-FRAME-STREAM-INF absent for Samsung profile" =
  let samsung = {
    independent_segments = false; playlist_type = false;
    session_data = false; start_offset = false;
    iframe_stream = false;
  } in
  let ifs : Iframe_stream.t = {
    data = String.make 5774 '\x00';
    init_end = 774;
    frame_ranges = Array.init 5 ~f:(fun i -> (774 + i * 1000, 1000));
    thumb_width = 159;
    thumb_height = 90;
    frame_duration_secs = 2.0;
  } in
  let playlist =
    master ~profile:samsung ~iframe_stream:ifs ~title:"Test"
      ~video:sample_video ~audio:sample_audio
      ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
      ~average_bandwidth_bps:4_200_000 ()
  in
  Stdlib.Printf.printf "%b\n"
    (String.is_substring playlist ~substring:"#EXT-X-I-FRAME-STREAM-INF:");
  [%expect {| false |}]
