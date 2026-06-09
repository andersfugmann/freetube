open! Base
open Util

module Log = (val Log_src.src_log ~doc:"DASH manifest generation" Stdlib.__MODULE__)
let _ = Log.debug

let content_type = "application/dash+xml"

let secs_of_usec usec = Float.of_int usec /. 1_000_000.

let attr name value = (("", name), value)

let tag name attrs children =
  Ezxmlm.make_tag name (attrs, children)



let total_duration_secs segments =
  Array.fold segments ~init:0 ~f:(fun acc (s : Producer.Segment_info.t) ->
    acc + s.length_usec)
  |> secs_of_usec

let pt_duration_secs secs =
  Printf.sprintf "PT%.3fS" secs

let iso8601_of_ms ms =
  let span = Ptime.Span.of_int_s (ms / 1000) in
  match Ptime.of_span span with
  | Some t -> Ptime.to_rfc3339 ~tz_offset_s:0 t
  | None -> "1970-01-01T00:00:00Z"

module Stream = Youtube.Video_info.Stream

let video_bitrate_bps (s : Stream.t) =
  let kbps =
    match s.vbr with
    | Some v -> v
    | None -> Option.value s.tbr ~default:0.0
  in
  Float.to_int (kbps *. 1000.0)

let audio_bitrate_bps (s : Stream.t) =
  Float.to_int (Option.value s.abr ~default:0.0 *. 1000.0)

let segment_start_number ~is_live segments =
  match is_live, Array.length segments > 0 with
  | true, true ->
    let s0 = segments.(0) in
    s0.Producer.Segment_info.start_usec / s0.length_usec
  | _ -> 0

let mime_type_of ~media container =
  match media, container with
  | `Video, Producer.Container.Webm -> "video/webm"
  | `Audio, Producer.Container.Webm -> "audio/webm"
  | `Video, _ -> "video/mp4"
  | `Audio, _ -> "audio/mp4"

let ext_of container =
  Producer.Container.to_ext container

let segment_template ~prefix ~is_live ~timescale ~container segments =
  let ext = ext_of container in
  let duration_ticks =
    let n = Array.length segments in
    match n > 0 with
    | true ->
      let avg_dur = total_duration_secs segments /. Float.of_int n in
      Float.to_int (avg_dur *. Float.of_int timescale)
    | false -> 0
  in
  let start_number = segment_start_number ~is_live segments in
  tag "SegmentTemplate"
    [ attr "timescale" (Int.to_string timescale)
    ; attr "duration" (Int.to_string duration_ticks)
    ; attr "startNumber" (Int.to_string start_number)
    ; attr "initialization" (prefix ^ "/init." ^ ext)
    ; attr "media" (prefix ^ "/seg/$Number$." ^ ext)
    ] []

let video_adaptation_set ~is_live ~timescale ~container
      ~(video : Stream.t) ~video_rfc6381 video_segments =
  let width = Option.value video.width ~default:0 in
  let height = Option.value video.height ~default:0 in
  let fps = Option.value video.fps ~default:0.0 in
  let codecs = video_rfc6381 in
  let seg_tmpl = segment_template ~prefix:"video" ~is_live ~timescale ~container video_segments in
  tag "AdaptationSet"
    [ attr "mimeType" (mime_type_of ~media:`Video container)
    ; attr "codecs" codecs
    ; attr "width" (Int.to_string width)
    ; attr "height" (Int.to_string height)
    ; attr "frameRate" (Printf.sprintf "%.3f" fps)
    ; attr "subsegmentAlignment" "true"
    ]
    [ seg_tmpl
    ; tag "Representation"
        [ attr "id" "video"
        ; attr "bandwidth" (Int.to_string (video_bitrate_bps video))
        ]
        []
    ]

let audio_adaptation_set ~is_live ~timescale ~container
      ~(audio : Stream.t) ~audio_rfc6381 audio_segments =
  let codecs = audio_rfc6381 in
  let channels = Option.value audio.audio_channels ~default:2 in
  let sample_rate = Option.value audio.asr_ ~default:0 in
  let seg_tmpl = segment_template ~prefix:"audio" ~is_live ~timescale ~container audio_segments in
  tag "AdaptationSet"
    [ attr "mimeType" (mime_type_of ~media:`Audio container)
    ; attr "codecs" codecs
    ; attr "subsegmentAlignment" "true"
    ; attr "lang" (Option.value audio.language ~default:"und")
    ]
    [ seg_tmpl
    ; tag "Representation"
        [ attr "id" "audio"
        ; attr "bandwidth" (Int.to_string (audio_bitrate_bps audio))
        ; attr "audioSamplingRate" (Int.to_string sample_rate)
        ]
        [ tag "AudioChannelConfiguration"
            [ attr "schemeIdUri"
                "urn:mpeg:dash:23003:3:audio_channel_configuration:2011"
            ; attr "value" (Int.to_string channels)
            ] []
        ]
    ]

let trickmode_adaptation_set (iframe : Storyboard.t) =
  let frame_count = Storyboard.frame_count iframe in
  let dur = Storyboard.frame_duration_secs iframe in
  let total_dur = Float.of_int frame_count *. dur in
  let data_len = String.length (Storyboard.data iframe) in
  let bandwidth =
    match Float.(total_dur > 0.) with
    | true -> Float.to_int (Float.of_int (data_len * 8) /. total_dur)
    | false -> 0
  in
  let timescale = 1000 in
  let dur_ticks = Float.to_int (dur *. 1000.0) in
  let init_range = Printf.sprintf "0-%d" (iframe.init_end - 1) in
  let segment_urls =
    Array.to_list iframe.frame_ranges
    |> List.map ~f:(fun (offset, len) ->
      tag "SegmentURL"
        [ attr "mediaRange" (Printf.sprintf "%d-%d" offset (offset + len - 1)) ] [])
  in
  tag "AdaptationSet"
    [ attr "mimeType" "video/mp4"
    ; attr "codecs" "avc1.42c00d"
    ; attr "contentType" "video"
    ]
    [ tag "EssentialProperty"
        [ attr "schemeIdUri" "http://dashif.org/guidelines/trickmode"
        ; attr "value" "video"
        ] []
    ; tag "Representation"
        [ attr "id" "trickmode"
        ; attr "bandwidth" (Int.to_string bandwidth)
        ; attr "width" (Int.to_string (Storyboard.thumb_width iframe))
        ; attr "height" (Int.to_string (Storyboard.thumb_height iframe))
        ]
        [ tag "BaseURL" [] [ `Data "iframe/stream.mp4" ]
        ; tag "SegmentList"
            [ attr "timescale" (Int.to_string timescale)
            ; attr "duration" (Int.to_string dur_ticks)
            ]
            (tag "Initialization" [ attr "range" init_range ] []
             :: segment_urls)
        ]
    ]

let mpd ~title ~is_live ~start_walltime_ms ~container
      ~(video : Stream.t) ~(audio : Stream.t)
      ~video_rfc6381 ~audio_rfc6381
      ~video_segments ~audio_segments ?iframe_stream () =
  let timescale = 1000 in
  let duration_secs =
    Float.max (total_duration_secs video_segments) (total_duration_secs audio_segments)
  in
  let mpd_type = match is_live with true -> "dynamic" | false -> "static" in
  let n_video = Array.length video_segments in
  let min_buffer_secs =
    match n_video > 0 with
    | true -> 2.0 *. total_duration_secs video_segments /. Float.of_int n_video
    | false -> 2.0
  in
  let base_attrs =
    [ attr "xmlns" "urn:mpeg:dash:schema:mpd:2011"
    ; attr "profiles" "urn:mpeg:dash:profile:isoff-on-demand:2011"
    ; attr "type" mpd_type
    ; attr "minBufferTime" (pt_duration_secs min_buffer_secs)
    ]
  in
  let extra_attrs =
    match is_live with
    | false ->
      [ attr "mediaPresentationDuration" (pt_duration_secs duration_secs) ]
    | true ->
      [ attr "availabilityStartTime" (iso8601_of_ms start_walltime_ms)
      ; attr "minimumUpdatePeriod" "PT6S"
      ; attr "timeShiftBufferDepth" (pt_duration_secs duration_secs)
      ]
  in
  let program_info =
    tag "ProgramInformation" []
      [ tag "Title" [] [ `Data title ] ]
  in
  let period =
    let adaptation_sets =
      [ video_adaptation_set ~is_live ~timescale ~container ~video ~video_rfc6381 video_segments
      ; audio_adaptation_set ~is_live ~timescale ~container ~audio ~audio_rfc6381 audio_segments
      ] @ (match iframe_stream with
           | None -> []
           | Some ifs -> [ trickmode_adaptation_set ifs ])
    in
    tag "Period" [] adaptation_sets
  in
  let mpd_node = tag "MPD" (base_attrs @ extra_attrs) [ program_info; period ] in
  let buf = Buffer.create 2048 in
  let o = Xmlm.make_output ~decl:true ~indent:(Some 2) (`Buffer buf) in
  let frag = function
    | `El (tag, children) -> `El (tag, children)
    | `Data d -> `Data d
  in
  Xmlm.output_doc_tree frag o (None, mpd_node);
  Buffer.contents buf

(* ── Tests ─────────────────────────────────────────────────────────── *)

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
  format_note = None;
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

let sample_video_segments : Producer.Segment_info.t array = [|
  { start_usec = 0;         length_usec = 4_000_000; byte_length = 500_000 };
  { start_usec = 4_000_000; length_usec = 4_000_000; byte_length = 480_000 };
  { start_usec = 8_000_000; length_usec = 3_000_000; byte_length = 350_000 };
|]

let sample_audio_segments : Producer.Segment_info.t array = [|
  { start_usec = 0;         length_usec = 4_000_000; byte_length = 64_000 };
  { start_usec = 4_000_000; length_usec = 4_000_000; byte_length = 64_000 };
  { start_usec = 8_000_000; length_usec = 3_000_000; byte_length = 48_000 };
|]

let%expect_test "VOD MPD is valid XML with expected structure" =
  let result = mpd ~title:"Test Video"
    ~is_live:false ~start_walltime_ms:0 ~container:Producer.Container.Mp4
    ~video:sample_video ~audio:sample_audio
    ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
    ~video_segments:sample_video_segments
    ~audio_segments:sample_audio_segments ()
  in
  let has s = String.is_substring result ~substring:s in
  Stdlib.Printf.printf "xml_decl=%b static=%b period=%b video_as=%b audio_as=%b init=%b seg_tmpl=%b duration=%b\n"
    (has "<?xml")
    (has "type=\"static\"")
    (has "<Period")
    (has "mimeType=\"video/mp4\"")
    (has "mimeType=\"audio/mp4\"")
    (has "init.mp4")
    (has "seg/$Number$.mp4")
    (has "mediaPresentationDuration");
  [%expect {| xml_decl=true static=true period=true video_as=true audio_as=true init=true seg_tmpl=true duration=true |}]

let%expect_test "VOD MPD contains correct codec strings" =
  let result = mpd ~title:"Test Video"
    ~is_live:false ~start_walltime_ms:0 ~container:Producer.Container.Mp4
    ~video:sample_video ~audio:sample_audio
    ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
    ~video_segments:sample_video_segments
    ~audio_segments:sample_audio_segments ()
  in
  Stdlib.Printf.printf "video_codec=%b audio_codec=%b\n"
    (String.is_substring result ~substring:"avc1.640028")
    (String.is_substring result ~substring:"mp4a.40.2");
  [%expect {| video_codec=true audio_codec=true |}]

let%expect_test "live MPD has dynamic type and availability start" =
  let result = mpd ~title:"Test Video"
    ~is_live:true ~start_walltime_ms:1_700_000_000_000 ~container:Producer.Container.Mp4
    ~video:sample_video ~audio:sample_audio
    ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
    ~video_segments:sample_video_segments
    ~audio_segments:sample_audio_segments ()
  in
  let has s = String.is_substring result ~substring:s in
  Stdlib.Printf.printf "dynamic=%b avail_start=%b update_period=%b buffer_depth=%b no_duration=%b\n"
    (has "type=\"dynamic\"")
    (has "availabilityStartTime")
    (has "minimumUpdatePeriod")
    (has "timeShiftBufferDepth")
    (not (has "mediaPresentationDuration"));
  [%expect {| dynamic=true avail_start=true update_period=true buffer_depth=true no_duration=true |}]

let%expect_test "segment numbering uses absolute IDs for live" =
  let live_segments : Producer.Segment_info.t array = [|
    { start_usec = 20_000_000; length_usec = 4_000_000; byte_length = 100 };
    { start_usec = 24_000_000; length_usec = 4_000_000; byte_length = 100 };
  |] in
  let result = mpd ~title:"Test Video"
    ~is_live:true ~start_walltime_ms:0 ~container:Producer.Container.Mp4
    ~video:sample_video ~audio:sample_audio
    ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
    ~video_segments:live_segments
    ~audio_segments:live_segments ()
  in
  Stdlib.Printf.printf "start_number_5=%b template=%b\n"
    (String.is_substring result ~substring:"startNumber=\"5\"")
    (String.is_substring result ~substring:"seg/$Number$.mp4");
  [%expect {| start_number_5=true template=true |}]

let%expect_test "WebM container uses webm MIME types and extensions" =
  let result = mpd ~title:"Test Video"
    ~is_live:false ~start_walltime_ms:0 ~container:Producer.Container.Webm
    ~video:sample_video ~audio:sample_audio
    ~video_rfc6381:"avc1.640028" ~audio_rfc6381:"mp4a.40.2"
    ~video_segments:sample_video_segments
    ~audio_segments:sample_audio_segments ()
  in
  let has s = String.is_substring result ~substring:s in
  Stdlib.Printf.printf "video_webm=%b audio_webm=%b init_webm=%b seg_webm=%b\n"
    (has "mimeType=\"video/webm\"")
    (has "mimeType=\"audio/webm\"")
    (has "init.webm")
    (has "seg/$Number$.webm");
  [%expect {| video_webm=true audio_webm=true init_webm=true seg_webm=true |}]
