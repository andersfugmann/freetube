open! Base
open Util

module Log = (val Log_src.src_log ~doc:"I-frame stream from storyboard" Stdlib.__MODULE__)

type t = {
  data : string;
  init_end : int;
  frame_ranges : (int * int) array;
  thumb_width : int;
  thumb_height : int;
  frame_duration_secs : float;
}

let frame_count t = Array.length t.frame_ranges
let thumb_width t = t.thumb_width
let thumb_height t = t.thumb_height
let frame_duration_secs t = t.frame_duration_secs
let data t = t.data

let index_fmp4 output =
  let len = String.length output in
  let rec find_frames pos acc =
    match Bmff.find_box output ~box_type:"moof" ~pos ~limit:(len - pos) with
    | None -> List.rev acc
    | Some moof ->
      let mdat =
        Bmff.find_box output ~box_type:"mdat"
          ~pos:(moof.offset + moof.size)
          ~limit:(len - moof.offset - moof.size)
      in
      let frame_end = match mdat with
        | Some m -> m.offset + m.size
        | None -> moof.offset + moof.size
      in
      let range = (moof.offset, frame_end - moof.offset) in
      find_frames frame_end (range :: acc)
  in
  match Bmff.find_box output ~box_type:"moof" ~pos:0 ~limit:len with
  | None -> 0, [||]
  | Some moof ->
    let init_end = moof.offset in
    let frame_ranges = find_frames 0 [] |> Array.of_list in
    init_end, frame_ranges

let create ~env ~storyboard =
  let columns = Storyboard.columns storyboard in
  let rows = Storyboard.rows storyboard in
  let thumb_w = Storyboard.thumb_width storyboard in
  let thumb_h = Storyboard.thumb_height storyboard in
  let count = Storyboard.count storyboard in
  let thumbs_per_sprite = columns * rows in
  let frag_duration = Storyboard.fragment_duration storyboard ~id:0 in
  let interval = frag_duration /. Float.of_int thumbs_per_sprite in
  (* Collect all sprite sheet JPEGs in order *)
  let sprite_buf = Buffer.create (count * 50_000) in
  for frag_idx = 0 to count - 1 do
    let sprite_data = Storyboard.fetch storyboard ~id:frag_idx in
    Buffer.add_string sprite_buf sprite_data
  done;
  let input_data = Buffer.contents sprite_buf in
  Log.info (fun m -> m "iframe_stream: encoding %d sprites (%dx%d grid, interval=%.2fs)"
               count columns rows interval);
  let vf = Printf.sprintf "untile=%dx%d,settb=AVTB,setpts=N*%f/TB"
      columns rows interval in
  let encode_args =
    [ "-f"; "image2pipe"; "-framerate"; "1"; "-i"; "pipe:0";
      "-vf"; vf;
      "-c:v"; "libx264"; "-preset"; "ultrafast"; "-crf"; "23";
      "-x264-params"; "keyint=1:min-keyint=1";
      "-pix_fmt"; "yuv420p"; "-vsync"; "0";
      "-movflags"; "+frag_keyframe+empty_moov+default_base_moof+separate_moof";
      "-frag_duration"; "0";
      "-f"; "mp4"; "pipe:1" ]
  in
  let fmp4_output = Ffmpeg.run_ffmpeg ~env encode_args input_data in
  let init_end, frame_ranges = index_fmp4 fmp4_output in
  Log.info (fun m -> m "iframe_stream: produced %d frames, init=%d bytes, total=%d bytes"
               (Array.length frame_ranges) init_end (String.length fmp4_output));
  { data = fmp4_output; init_end; frame_ranges;
    thumb_width = thumb_w; thumb_height = thumb_h;
    frame_duration_secs = interval }
