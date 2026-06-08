open! Base
open Util

module Log = (val Log_src.src_log ~doc:"stream selection" Stdlib.__MODULE__)

type selection =
  | Muxed of Youtube.Video_info.Stream.t
  | Separate of { video : Youtube.Video_info.Stream.t; audio : Youtube.Video_info.Stream.t }

type _ compare =
  | Cmp: (Youtube.Video_info.Stream.t -> 'key) * ('key -> 'key -> int) * [ `Asc | `Desc ] -> int compare


let compare =
  let cmp (Cmp (to_key, compare, dir)) =
    let c compare = match dir with
      | `Asc -> fun v1 v2 -> compare v1 v2
      | `Desc -> fun v1 v2 -> compare v2 v1
    in
    fun s1 s2 ->
      let v1 = to_key s1 in
      let v2 = to_key s2 in
      c compare v1 v2
  in
  let rec compare = function
    | [] -> fun _ _ -> 0
    | x :: xs ->
        let next = compare xs in
        let x = cmp x in
        fun s1 s2 ->
          match x s1 s2 with
          | -1 -> -1
          | 1 -> 1
          | _ -> next s1 s2
  in
  compare

let classify (s : Youtube.Video_info.Stream.t) =
  match s.protocol, Option.is_some s.vcodec, Option.is_some s.acodec with
  | Unsupported _, _, _ -> `Drop
  | _, false, false -> `Drop
  | _ when String.is_suffix ~suffix:"-drc" s.format_id -> `Drop (* Drop dynamic range compression audio *)
  | _ when String.is_suffix ~suffix:"-dash" s.format_id -> `Drop (* Drop dash streams *)
  | _, true, true -> `Muxed
  | _, true, false -> `Video
  | _, false, true -> `Audio

(* Compare video based on encoding, bitrate, dynamic range et. al. *)
let compare_video =
  let open Youtube.Video_info.Stream in
  (*
  let bitrate s =
    let bitrate_k = match s.vbr with
      | Some v -> v *. 1000.0
      | None -> Option.value s.tbr ~default:0.0 *. 1000.0
    in
    match Option.map ~f:fst s.vcodec with
    | Some Av1 -> bitrate_k /. 0.35
    | Some Hevc -> bitrate_k /. 0.40
    | Some Vp9 -> bitrate_k /. 0.55
    | Some Avc -> bitrate_k /. 1.0
    | Some Unknown -> 0.0
    | None -> 0.0
  in
  *)

  let ordering = [
    Cmp ((fun s -> Option.value ~default:0 s.width), Int.compare, `Desc);
    Cmp ((fun s -> Option.value s.dynamic_range ~default:Codec.Dynamic_range.Sdr), Codec.Dynamic_range.compare, `Asc);
    Cmp ((fun s -> Option.value s.fps ~default:0.0 *. 1000.0), Float.compare, `Desc);
    Cmp ((fun s -> Option.map ~f:fst s.vcodec |> Option.value ~default:Codec.Video.Unknown), Codec.Video.compare, `Asc);
  ] in
  compare ordering


let compare_audio =
  let open Youtube.Video_info.Stream in
  let bitrate s =
    let factor =
      match Option.map ~f:fst s.acodec with
      | Some Opus -> 0.7
      | Some Aac -> 0.9
      | Some Vorbis -> 1.0
      | Some Flac -> 4.0
      | Some Unknown -> 1.0
      | None -> 1.0
    in
    let bitrate = Option.value ~default:0.0 s.abr in
    bitrate /. factor
  in
  let has_drc s = String.is_suffix ~suffix:"-drc" s.format_id in

  let ordering = [
      Cmp (has_drc, Bool.compare, `Desc);
      Cmp ((fun s -> s.language_preference), Int.compare, `Desc);
      Cmp (bitrate, Float.compare, `Desc);
    ]
  in
  compare ordering


(* Main entry point *)
let select ~video_codecs ~audio_codecs ~max_width ~max_height streams =
  let usable (s: Youtube.Video_info.Stream.t) =
    let video_ok =
      match s.vcodec with
      | None -> true
      | Some (codec, _) ->
          List.mem video_codecs codec ~equal:Codec.Video.equal
          && Option.value_map ~default:false ~f:(fun w -> w <= max_width) s.width
          && Option.value_map ~default:false ~f:(fun h -> h <= max_height) s.height
    in
    let audio_ok =
      match s.acodec with
      | None -> true
      | Some (codec, _) ->
          List.mem audio_codecs codec ~equal:Codec.Audio.equal
          && not (String.is_suffix ~suffix:"-drc" s.format_id)
    in
    (Option.is_some s.vcodec || Option.is_some s.acodec)
    && video_ok && audio_ok
  in

  let streams =
    streams
    |> List.sort ~compare:(fun s1 s2 -> String.compare s1.Youtube.Video_info.Stream.format_id s2.format_id)
    |> List.map ~f:(fun stream -> classify stream, stream)
    |> List.filter_map ~f:(function
        | `Drop, _ -> None
        | (`Video, _) as v -> Some v
        | (`Audio, _) as a -> Some a
        | (`Muxed, _) as m -> Some m
      )
    |> List.stable_sort ~compare:(fun s1 s2 -> match s1, s2 with
        | (`Video, s1), (`Video, s2) -> compare_video s1 s2
        | (`Audio, a1), (`Audio, a2) -> compare_audio a1 a2
        | (`Muxed, s1), (`Muxed, s2) -> begin
            match compare_video s1 s2 with
            | 0 -> compare_audio s1 s2
            | n -> n
          end
        | (`Video, _), _ -> -1 (* First *)
        | (`Audio, _), (`Video, _) -> 1
        | (`Audio, _), (`Muxed, _) -> -1
        | (`Muxed, _), _ -> 1 (* Last *)
      )
    |> List.map ~f:(fun (t, s) -> (t, s, usable s))
    |> (fun s ->
        List.map s ~f:(fun (_t, s, usable) ->
            usable, Youtube.Video_info.Stream.to_string_hum s
          )
        |> List.map ~f:(function
            | (true, s) -> " * " ^ s
            | (false, s) -> "   " ^ s
          )
         |> String.concat ~sep:"\n"
         |> fun str -> Log.info (fun m -> m "Streams:\n%s" str);
         s
      )
  in
  match
    List.find_map ~f:(function `Video, v, true -> Some v | _ -> None) streams,
    List.find_map ~f:(function `Audio, a, true -> Some a | _ -> None) streams,
    List.find_map ~f:(function `Muxed, m, true -> Some m | _ -> None) streams
  with
  | Some v, Some a, _ ->
    Log.info (fun l -> l "selected:\n   %s\n   %s"
                 (Youtube.Video_info.Stream.to_string_hum v)
                 (Youtube.Video_info.Stream.to_string_hum a));
    Some (Separate { video = v; audio = a })
  | _, _, Some m ->
    Log.info (fun l -> l "selected:\n   %s" (Youtube.Video_info.Stream.to_string_hum m));
    Some (Muxed m)
  | _ -> None

let select_storyboard streams =
  Youtube.Video_info.Storyboard.of_streams streams

(* Tests *)

let stream ?(format_id="") ?(url="") ?(ext=Youtube.Video_info.Container.Mp4) ?vcodec ?acodec
    ?width ?height ?fps ?tbr ?vbr ?abr ?(dynamic_range=None) () =
  let vcodec = Option.map vcodec ~f:(fun s -> Codec.Video.of_rfc6381 s, s) in
  let acodec = Option.map acodec ~f:(fun s -> Codec.Audio.of_rfc6381 s, s) in
  { Youtube.Video_info.Stream.
    format_id; format_note = None; url; ext;
    vcodec; acodec;
    width; height; fps; tbr; vbr; abr;
    asr_ = None; audio_channels = None;
    dynamic_range;
    protocol = Youtube.Video_info.Protocol_kind.Https;
    fragment_base_url = None; fragments = []; http_headers = [];
    language = None;
    language_preference = 10;
    rows = None; columns = None;
  }

let describe = function
  | None -> "none"
  | Some (Muxed s) ->
    let vraw = match s.vcodec with Some (_, r) -> r | None -> "?" in
    let araw = match s.acodec with Some (_, r) -> r | None -> "?" in
    Printf.sprintf "muxed %s v=%s a=%s %dx%d"
      s.url vraw araw
      (Option.value s.width ~default:0)
      (Option.value s.height ~default:0)
  | Some (Separate { video; audio }) ->
    let vraw = match video.vcodec with Some (_, r) -> r | None -> "?" in
    let araw = match audio.acodec with Some (_, r) -> r | None -> "?" in
    Printf.sprintf "separate v=%s@%dx%d a=%s"
      vraw
      (Option.value video.width ~default:0)
      (Option.value video.height ~default:0)
      araw

let%expect_test "prefers separate over muxed when both viable" =
  let streams = [
    stream ~format_id:"vid" ~url:"u/v" ~vcodec:"avc1.640028" ~width:1920 ~height:1080 ~tbr:5000.0 ();
    stream ~format_id:"aud" ~url:"u/a" ~acodec:"opus" ~abr:160.0 ();
    stream ~format_id:"mux" ~url:"u/m" ~vcodec:"avc1.640028" ~acodec:"mp4a.40.2"
      ~width:1280 ~height:720 ~tbr:3000.0 ();
  ] in
  let r = select ~video_codecs:[Codec.Video.Avc] ~audio_codecs:[Codec.Audio.Opus; Codec.Audio.Aac]
    ~max_width:3840 ~max_height:2160 streams in
  Stdio.printf "%s\n" (describe r);
  [%expect {| separate v=avc1.640028@1920x1080 a=opus |}]

let%expect_test "falls back to muxed when no separate video/audio available" =
  let streams = [
    stream ~format_id:"mux" ~url:"u/m" ~vcodec:"avc1.640028" ~acodec:"mp4a.40.2"
      ~width:1280 ~height:720 ~tbr:3000.0 ();
  ] in
  let r = select ~video_codecs:[Codec.Video.Avc] ~audio_codecs:[Codec.Audio.Aac]
    ~max_width:3840 ~max_height:2160 streams in
  Stdio.printf "%s\n" (describe r);
  [%expect {| muxed u/m v=avc1.640028 a=mp4a.40.2 1280x720 |}]

let%expect_test "drops streams above 4K" =
  let streams = [
    stream ~format_id:"8k" ~url:"u/8k" ~vcodec:"av01.0.16M.08" ~width:7680 ~height:4320 ~tbr:50000.0 ();
    stream ~format_id:"4k" ~url:"u/4k" ~vcodec:"av01.0.12M.08" ~width:3840 ~height:2160 ~tbr:20000.0 ();
    stream ~format_id:"aud" ~url:"u/a" ~acodec:"opus" ~abr:160.0 ();
  ] in
  let r = select ~video_codecs:[Codec.Video.Av1] ~audio_codecs:[Codec.Audio.Opus]
    ~max_width:3840 ~max_height:2160 streams in
  Stdio.printf "%s\n" (describe r);
  [%expect {| separate v=av01.0.12M.08@3840x2160 a=opus |}]

let%expect_test "filters by device codec capability" =
  let streams = [
    stream ~format_id:"av1" ~url:"u/av1" ~vcodec:"av01.0.08M.08" ~width:1920 ~height:1080 ~tbr:6000.0 ();
    stream ~format_id:"h264" ~url:"u/h264" ~vcodec:"avc1.640028" ~width:1920 ~height:1080 ~tbr:5000.0 ();
    stream ~format_id:"aud" ~url:"u/a" ~acodec:"mp4a.40.2" ~abr:128.0 ();
  ] in
  let r = select ~video_codecs:[Codec.Video.Avc] ~audio_codecs:[Codec.Audio.Aac]
    ~max_width:3840 ~max_height:2160 streams in
  Stdio.printf "%s\n" (describe r);
  [%expect {| separate v=avc1.640028@1920x1080 a=mp4a.40.2 |}]

let%expect_test "prefers HDR at same resolution" =
  let streams = [
    stream ~format_id:"hdr" ~url:"u/hdr" ~vcodec:"vp09.02.51.10" ~width:3840 ~height:2160
      ~tbr:18000.0 ~dynamic_range:(Some Codec.Dynamic_range.Hdr10) ();
    stream ~format_id:"sdr" ~url:"u/sdr" ~vcodec:"vp09.00.51.08" ~width:3840 ~height:2160 ~tbr:20000.0 ();
    stream ~format_id:"aud" ~url:"u/a" ~acodec:"opus" ~abr:160.0 ();
  ] in
  let r = select ~video_codecs:[Codec.Video.Vp9] ~audio_codecs:[Codec.Audio.Opus]
    ~max_width:3840 ~max_height:2160 streams in
  Stdio.printf "%s\n" (describe r);
  [%expect {| separate v=vp09.02.51.10@3840x2160 a=opus |}]

let%expect_test "no compatible stream returns None" =
  let streams = [
    stream ~format_id:"av1" ~url:"u/av1" ~vcodec:"av01.0.08M.08" ~width:1920 ~height:1080 ();
    stream ~format_id:"aud" ~url:"u/a" ~acodec:"opus" ~abr:160.0 ();
  ] in
  let r = select ~video_codecs:[Codec.Video.Avc] ~audio_codecs:[Codec.Audio.Aac]
    ~max_width:3840 ~max_height:2160 streams in
  Stdio.printf "%s\n" (describe r);
  [%expect {| none |}]

let%expect_test "selects from real yt-dlp testdata" =
  let content = Stdio.In_channel.read_all "../youtube/testdata.json" in
  let json = Yojson.Safe.from_string content in
  match Youtube.Video_info.of_yojson json with
  | Error e -> Stdio.printf "Error: %s" e
  | Ok detail ->
      let pick ~name vc ac =
        let r = select ~video_codecs:vc ~audio_codecs:ac ~max_width:3840 ~max_height:2160 detail.streams in
        Stdio.printf "%s: %s\n" name (describe r)
      in
      pick ~name:"apple-tv" [Codec.Video.Hevc; Codec.Video.Avc] [Codec.Audio.Aac];
      pick ~name:"samsung" [Codec.Video.Av1; Codec.Video.Vp9; Codec.Video.Hevc; Codec.Video.Avc]
        [Codec.Audio.Opus; Codec.Audio.Aac; Codec.Audio.Flac];
      pick ~name:"legacy" [Codec.Video.Avc] [Codec.Audio.Aac];
      [%expect {|
        apple-tv: separate v=avc1.64002a@1920x1080 a=mp4a.40.2
        samsung: separate v=vp9.2@3840x2160 a=opus
        legacy: separate v=avc1.64002a@1920x1080 a=mp4a.40.2
        |}]
