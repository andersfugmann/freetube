open! Base

module Video_info = Youtube.Video_info

(** What the on-the-wire bytes look like for a given playable stream.

    yt-dlp's [ext] alone is ambiguous (it lumps mp4 video and m4a audio into
    [Mp4]). [t] is the typed projection consumed downstream: each constructor
    pins down both the container family and the track role, so the producer
    dispatch is total. *)
type t =
  | Mp4_dash
  | M4a_dash
  | Webm_dash
[@@deriving compare, equal]

let to_string = function
  | Mp4_dash  -> "mp4_dash"
  | M4a_dash  -> "m4a_dash"
  | Webm_dash -> "webm_dash"

let has_video (s : Video_info.Stream.t) = Option.is_some s.vcodec
let has_audio (s : Video_info.Stream.t) = Option.is_some s.acodec

let of_stream (s : Video_info.Stream.t) =
  match s.ext, has_video s, has_audio s with
  | Mp4,     true,  _    -> Some Mp4_dash
  | Mp4,     false, true -> Some M4a_dash
  | Webm,    _,     _    -> Some Webm_dash
  | Mp4,     false, false
  | Other _, _,     _    -> None

let%expect_test "of_stream mapping" =
  let mk ?vcodec ?acodec ext =
    Selector.stream ?vcodec ?acodec ~ext ()
  in
  let pp s =
    match of_stream s with
    | None -> "none"
    | Some t -> to_string t
  in
  Stdio.printf "%s\n" (pp (mk ~vcodec:"avc1.640028" Mp4));
  Stdio.printf "%s\n" (pp (mk ~acodec:"mp4a.40.2"   Mp4));
  Stdio.printf "%s\n" (pp (mk ~vcodec:"av01.0.13M.10" Webm));
  Stdio.printf "%s\n" (pp (mk ~acodec:"opus" Webm));
  Stdio.printf "%s\n" (pp (mk (Other "mhtml")));
  [%expect {|
    mp4_dash
    m4a_dash
    webm_dash
    webm_dash
    none
  |}]
