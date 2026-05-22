open! Base

module Container = struct
  type t = Mp4 | Webm | Other of string [@@deriving compare, equal]

  let of_string = function
    | "mp4" | "m4a" -> Mp4
    | "webm" -> Webm
    | other -> Other other

  let to_string = function
    | Mp4 -> "mp4"
    | Webm -> "webm"
    | Other s -> s

  let of_yojson = function
    | `String s -> Ok (of_string s)
    | _ -> Error "expected string for ext"
end

module Protocol_kind = struct
  type t = Https | Http_dash_segments | M3u8_native | Unsupported of string

  let of_string = function
    | "https" -> Https
    | "http_dash_segments" -> Http_dash_segments
    | "m3u8_native" | "m3u8" -> M3u8_native
    | other -> Unsupported other

  let of_yojson = function
    | `String s -> Ok (of_string s)
    | _ -> Error "expected string for protocol"

  let to_string_hum = function
    | Https -> "https"
    | Http_dash_segments -> "dash"
    | M3u8_native -> "m3u8"
    | Unsupported s -> s
end

(* yt-dlp emits the codec as a single string (e.g. "avc1.640028", "mp4a.40.2",
   "opus", "none"). We keep that raw string plus the codec family — actual
   parameter parsing lives in [Codec] and is done on demand. *)

type vcodec = (Codec.Video.t * string) option

let vcodec_of_yojson = function
  | `String s when not (String.Caseless.equal s "none") ->
      Ok (Some (Codec.Video.of_rfc6381 s, s))
  | _ -> Ok None

type acodec = (Codec.Audio.t * string) option

let acodec_of_yojson = function
  | `String s when not (String.Caseless.equal s "none") ->
      Ok (Some (Codec.Audio.of_rfc6381 s, s))
  | _ -> Ok None

type duration = float

let duration_of_yojson = function
  | `Float f -> Ok f
  | `Int i -> Ok (Float.of_int i)
  | `Null -> Ok 0.0
  | _ -> Error "expected number for duration"

module Http_headers = struct
  type t = (string * string) list

  let of_yojson = function
    | `Null -> Ok []
    | `Assoc kvs ->
        List.fold_result kvs ~init:[] ~f:(fun acc (k, v) ->
          match v with
          | `String s -> Ok ((k, s) :: acc)
          | _ -> Error "expected string http_headers value")
        |> Result.map ~f:List.rev
    | _ -> Error "expected object for http_headers"
end

module Fragment = struct
  type t = { url : string [@default ""]; duration : duration [@default 0.0] }
  [@@deriving of_yojson { strict = false }]
end

module Stream = struct
  type t = {
    format_id : string [@default ""];
    format_note : string option [@default None];
    url : string [@default ""];
    ext : Container.t [@default Container.Other ""];
    vcodec : vcodec [@default None];
    acodec : acodec [@default None];
    width : int option [@default None];
    height : int option [@default None];
    fps : float option [@default None];
    tbr : float option [@default None];
    vbr : float option [@default None];
    abr : float option [@default None];
    asr_ : int option [@key "asr"] [@default None];
    audio_channels : int option [@default None];
    dynamic_range : Codec.Dynamic_range.t option [@default None];
    protocol : Protocol_kind.t [@default Protocol_kind.Unsupported ""];
    fragment_base_url : string option [@default None];
    fragments : Fragment.t list [@default []];
    rows : int option [@default None];
    columns : int option [@default None];
    language : string option [@default None];
    language_preference : int [@default 10];
    http_headers : Http_headers.t [@default []];
  }
  [@@deriving of_yojson { strict = false }]

  let to_string_hum { format_id; width; height; vcodec; acodec; tbr; dynamic_range; ext; _ } =
    let vcodec = Option.value_map ~default:"----" ~f:(fun (c, _) -> Codec.Video.show c) vcodec in
    let acodec = Option.value_map ~default:"----" ~f:(fun (a, _) -> Codec.Audio.show a) acodec in
    let size = match width, height with
      | None, _ | _, None -> "----"
      | Some width, Some height -> Printf.sprintf "%dx%d" width height
    in
    let dr = Option.value_map ~default:"---" ~f:Codec.Dynamic_range.to_string dynamic_range in
    let ext = Container.to_string ext in
    let tbr = Option.value ~default:0.0 tbr in
    Printf.sprintf "%10s %5s %5s %9s %6s %5s %5.2f" format_id vcodec acodec size dr ext tbr
end

module Storyboard = struct
  type fragment = { url : string; duration : float }

  type t = {
    width : int;
    height : int;
    columns : int;
    rows : int;
    fps : float;
    fragments : fragment list;
  }

  let is_storyboard (s : Stream.t) =
    match s.protocol with
    | Protocol_kind.Unsupported "mhtml" -> true
    | _ -> false

  let of_streams streams =
    List.filter streams ~f:is_storyboard
    |> List.sort ~compare:(fun (a : Stream.t) (b : Stream.t) ->
         Int.compare
           (Option.value b.width ~default:0)
           (Option.value a.width ~default:0))
    |> List.hd
    |> Option.bind ~f:(fun (s : Stream.t) ->
         match s.width, s.height, s.columns, s.rows, s.fps with
         | Some width, Some height, Some columns, Some rows, Some fps ->
           let fragments =
             List.map s.fragments ~f:(fun (f : Fragment.t) ->
               { url = f.url; duration = f.duration })
           in
           Some { width; height; columns; rows; fps; fragments }
         | _ -> None)
end

type t = {
  id : string [@default ""];
  title : string [@default ""];
  duration_secs : duration [@key "duration"] [@default 0.0];
  thumbnail_url : string [@key "thumbnail"] [@default ""];
  is_live : bool [@default false];
  streams : Stream.t list [@key "formats"] [@default []];

}
[@@deriving of_yojson { strict = false }]

let%test_module "video_detail_of_yojson" =
  (module struct
    let json =
      Yojson.Safe.from_string
        {|{
             "id": "abc123",
             "title": "Example",
             "description": "desc",
             "channel": "FreeTube",
             "duration": 12.5,
             "view_count": 42,
             "thumbnail": "https://img.example/thumb.jpg",
             "is_live": false,
             "formats": [
               {
                 "format_id": "137",
                 "url": "https://video.example/137",
                 "ext": "mp4",
                 "vcodec": "avc1.640028",
                 "acodec": "none",
                 "protocol": "https",
                 "dynamic_range": "HDR10",
                 "asr": 48000,
                 "fragments": []
               },
               {
                 "format_id": "sb0",
                 "url": "https://video.example/sb0",
                 "ext": "mhtml",
                 "vcodec": "none",
                 "acodec": "none",
                 "protocol": "mhtml"
               },
               {
                 "format_id": "251",
                 "url": "https://video.example/251",
                 "ext": "webm",
                 "vcodec": "none",
                 "acodec": "opus",
                 "protocol": "https"
               },
               {
                 "format_id": "missing-url",
                 "url": "",
                 "ext": "mp4",
                 "protocol": "https"
               }
             ]
           }|}

    let%expect_test "parses all formats including unsupported" =
      match of_yojson json with
      | Error e -> Stdio.printf "Error: %s" e
      | Ok detail ->
          List.iter detail.streams ~f:(fun f ->
              Stdio.printf "%s %s\n" f.format_id (Container.to_string f.ext));
          [%expect {|
            137 mp4
            sb0 mhtml
            251 webm
            missing-url mp4 |}]

    let%expect_test "parses codec families with raw strings" =
      match of_yojson json with
      | Error e -> Stdio.printf "Error: %s" e
      | Ok detail ->
          List.iter detail.streams ~f:(fun f ->
              let vc = match f.vcodec with
                | Some (_, raw) -> raw
                | None -> "none"
              in
              let ac = match f.acodec with
                | Some (_, raw) -> raw
                | None -> "none"
              in
              Stdio.printf "%s v=%s a=%s\n" f.format_id vc ac);
          [%expect {|
            137 v=avc1.640028 a=none
            sb0 v=none a=none
            251 v=none a=opus
            missing-url v=none a=none |}]
  end)

let format_vcodec = function
  | Some (Codec.Video.Avc, raw) ->
      let p, l = Codec.Video.parse_avc raw in
      Printf.sprintf "avc1(p%d/l%d)" p l
  | Some (Codec.Video.Hevc, raw) ->
      let p, l = Codec.Video.parse_hevc raw in
      Printf.sprintf "hevc(p%d/l%d)" p l
  | Some (Codec.Video.Vp9, raw) ->
      Printf.sprintf "vp9(p%d)" (Codec.Video.parse_vp9 raw)
  | Some (Codec.Video.Av1, raw) ->
      let p, bd = Codec.Video.parse_av1 raw in
      Printf.sprintf "av1(p%d/%dbit)" p bd
  | Some (Codec.Video.Unknown, _) -> "unknown"
  | None -> "-"

let format_acodec = function
  | Some (Codec.Audio.Aac, raw) ->
      (match Codec.Audio.parse_aac raw with
       | Lc -> "aac-lc"
       | He -> "aac-he"
       | He_v2 -> "aac-hev2")
  | Some (Codec.Audio.Opus, _) -> "opus"
  | Some (Codec.Audio.Vorbis, _) -> "vorbis"
  | Some (Codec.Audio.Flac, _) -> "flac"
  | Some (Codec.Audio.Unknown, _) -> "unknown"
  | None -> "-"

let pp detail =
  Stdio.printf "Video: %s (%s)\n" detail.title detail.id;
  Stdio.printf "Duration: %.1fs\n" detail.duration_secs;
  Stdio.printf "Streams: %d\n" (List.length detail.streams);
  List.iter detail.streams ~f:(fun f ->
      let vc = format_vcodec f.vcodec in
      let ac = format_acodec f.acodec in
      let res = match f.width, f.height with
        | Some w, Some h -> Printf.sprintf "%dx%d" w h
        | _ -> "-"
      in
      let dr = match f.dynamic_range with
        | Some r -> Codec.Dynamic_range.to_string r
        | None -> "-"
      in
      Stdio.printf "  %3s: v=%14s a=%7s %9s %5s %s\n" f.format_id vc ac res (Container.to_string f.ext) dr)

let%expect_test "parses real yt-dlp testdata" =
  let content = Stdio.In_channel.read_all "testdata.json" in
  let json = Yojson.Safe.from_string content in
  match of_yojson json with
  | Error e -> Stdio.printf "Error: %s" e
  | Ok detail ->
      pp detail;
      [%expect {|
        Video: 4K HDR Winter Scenery with Dolby Atmos - Relaxing Snow Landscape for OLED TV Test (p1FNy7-BgHI)
        Duration: 214.0s
        Streams: 36
          sb2: v=             - a=      -     48x27 mhtml -
          sb1: v=             - a=      -     79x45 mhtml -
          sb0: v=             - a=      -    159x90 mhtml -
          139: v=             - a= aac-he         -   mp4 -
          249: v=             - a=   opus         -  webm -
          140: v=             - a= aac-lc         -   mp4 -
          251: v=             - a=   opus         -  webm -
           91: v= avc1(p77/l12) a= aac-he   256x144   mp4 sdr
          160: v= avc1(p77/l12) a=      -   256x144   mp4 sdr
          278: v=       vp9(p0) a=      -   256x144  webm sdr
          330: v=       vp9(p2) a=      -   256x144  webm hdr10
           92: v= avc1(p77/l21) a= aac-he   426x240   mp4 sdr
          133: v= avc1(p77/l21) a=      -   426x240   mp4 sdr
          242: v=       vp9(p0) a=      -   426x240  webm sdr
          331: v=       vp9(p2) a=      -   426x240  webm hdr10
           93: v= avc1(p77/l30) a= aac-lc   640x360   mp4 sdr
          134: v= avc1(p77/l30) a=      -   640x360   mp4 sdr
           18: v= avc1(p66/l30) a= aac-lc   640x360   mp4 sdr
          243: v=       vp9(p0) a=      -   640x360  webm sdr
          332: v=       vp9(p2) a=      -   640x360  webm hdr10
           94: v= avc1(p77/l31) a= aac-lc   854x480   mp4 sdr
          135: v= avc1(p77/l31) a=      -   854x480   mp4 sdr
          244: v=       vp9(p0) a=      -   854x480  webm sdr
          333: v=       vp9(p2) a=      -   854x480  webm hdr10
          300: v=avc1(p100/l32) a= aac-lc  1280x720   mp4 sdr
          298: v=avc1(p100/l32) a=      -  1280x720   mp4 sdr
          302: v=       vp9(p0) a=      -  1280x720  webm sdr
          334: v=       vp9(p2) a=      -  1280x720  webm hdr10
          301: v=avc1(p100/l42) a= aac-lc 1920x1080   mp4 sdr
          299: v=avc1(p100/l42) a=      - 1920x1080   mp4 sdr
          303: v=       vp9(p0) a=      - 1920x1080  webm sdr
          335: v=       vp9(p2) a=      - 1920x1080  webm hdr10
          308: v=       vp9(p0) a=      - 2560x1440  webm sdr
          336: v=       vp9(p2) a=      - 2560x1440  webm hdr10
          315: v=       vp9(p0) a=      - 3840x2160  webm sdr
          337: v=       vp9(p2) a=      - 3840x2160  webm hdr10
        |}]

let%expect_test "extracts highest-quality storyboard" =
  let content = Stdio.In_channel.read_all "testdata.json" in
  let json = Yojson.Safe.from_string content in
  match of_yojson json with
  | Error e -> Stdio.printf "Error: %s" e
  | Ok detail ->
    match Storyboard.of_streams detail.streams with
    | None -> Stdio.printf "no storyboard"
    | Some sb ->
      Stdio.printf "thumb=%dx%d grid=%dx%d fps=%.3f fragments=%d\n"
        sb.width sb.height sb.columns sb.rows sb.fps
        (List.length sb.fragments);
      [%expect {| thumb=159x90 grid=5x5 fps=0.505 fragments=5 |}]
