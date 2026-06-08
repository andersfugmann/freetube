open! Base
open Util

module Log = (val Log_src.src_log ~doc:"I-frame stream from storyboard" Stdlib.__MODULE__)

type t = {
  init_segment : string;
  frames : string array;
  thumb_width : int;
  thumb_height : int;
  frame_duration_secs : float;
}

let frame_count t = Array.length t.frames
let init_segment t = t.init_segment
let frame t ~id = t.frames.(id)
let thumb_width t = t.thumb_width
let thumb_height t = t.thumb_height
let frame_duration_secs t = t.frame_duration_secs

let split_fmp4_frames output =
  let len = String.length output in
  let rec find_moofs pos acc =
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
      let frame_data = String.sub output ~pos:moof.offset ~len:(frame_end - moof.offset) in
      find_moofs frame_end (frame_data :: acc)
  in
  let first_moof =
    Bmff.find_box output ~box_type:"moof" ~pos:0 ~limit:len
  in
  match first_moof with
  | None -> "", [||]
  | Some moof ->
    let init_data = String.sub output ~pos:0 ~len:moof.offset in
    let frames = find_moofs 0 [] |> Array.of_list in
    init_data, frames

let create ~env ~storyboard =
  let columns = Storyboard.columns storyboard in
  let rows = Storyboard.rows storyboard in
  let thumb_w = Storyboard.thumb_width storyboard in
  let thumb_h = Storyboard.thumb_height storyboard in
  let count = Storyboard.count storyboard in
  let thumbs_per_fragment = columns * rows in
  let total_thumbs =
    let full = (count - 1) * thumbs_per_fragment in
    (* Last fragment may be partial but we don't know — assume full *)
    full + thumbs_per_fragment
  in
  let fps = 1.0 /. 2.0 in
  (* Collect all sprite sheets and crop individual thumbnails via ffmpeg.
     We pipe each sprite sheet through ffmpeg with crop+output to get
     individual JPEG thumbnails, then encode them all into a single
     H.264 all-keyframe fMP4 stream. *)
  let thumbnail_jpegs = Buffer.create (total_thumbs * 4096) in
  let actual_thumb_count = ref 0 in
  for frag_idx = 0 to count - 1 do
    let sprite_data = Storyboard.fetch storyboard ~id:frag_idx in
    (* Extract individual thumbnails from the sprite grid using ffmpeg *)
    let proc_mgr = Eio.Stdenv.process_mgr env in
    for row = 0 to rows - 1 do
      for col = 0 to columns - 1 do
        let x = col * thumb_w in
        let y = row * thumb_h in
        let crop_filter = Printf.sprintf "crop=%d:%d:%d:%d" thumb_w thumb_h x y in
        Eio.Switch.run @@ fun sw ->
        let stdin_r, stdin_w = Eio.Process.pipe ~sw proc_mgr in
        let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
        let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
        let cmd = [ "ffmpeg"; "-hide_banner"; "-loglevel"; "error";
                    "-f"; "image2pipe"; "-i"; "pipe:0";
                    "-vf"; crop_filter;
                    "-f"; "image2pipe"; "-vcodec"; "mjpeg";
                    "pipe:1" ] in
        let process =
          Eio.Process.spawn ~sw proc_mgr
            ~stdin:stdin_r ~stdout:stdout_w ~stderr:stderr_w
            cmd
        in
        Eio.Flow.close stdin_r;
        Eio.Flow.close stdout_w;
        Eio.Flow.close stderr_w;
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Flow.copy_string sprite_data stdin_w;
          Eio.Flow.close stdin_w);
        let jpeg_data =
          Eio.Buf_read.parse_exn ~max_size:(1024 * 1024)
            Eio.Buf_read.take_all stdout_r
        in
        let _stderr =
          Eio.Buf_read.parse_exn ~max_size:(64 * 1024)
            Eio.Buf_read.take_all stderr_r
        in
        (match Eio.Process.await process with
         | `Exited 0 ->
           Buffer.add_string thumbnail_jpegs jpeg_data;
           Int.incr actual_thumb_count
         | `Exited code ->
           Log.warn (fun m -> m "iframe crop failed (exit %d) frag=%d row=%d col=%d"
                        code frag_idx row col)
         | `Signaled sig_ ->
           Log.warn (fun m -> m "iframe crop killed (signal %d) frag=%d row=%d col=%d"
                        sig_ frag_idx row col))
      done
    done
  done;
  let n_thumbs = !actual_thumb_count in
  Log.info (fun m -> m "iframe_stream: extracted %d thumbnails, encoding to H.264 fMP4" n_thumbs);
  (* Now encode all thumbnails into a single H.264 all-keyframe fMP4 stream *)
  let input_data = Buffer.contents thumbnail_jpegs in
  let encode_args =
    [ "-f"; "image2pipe"; "-framerate"; Printf.sprintf "%.6f" fps;
      "-i"; "pipe:0";
      "-c:v"; "libx264"; "-preset"; "ultrafast"; "-crf"; "28";
      "-x264-params"; "keyint=1:min-keyint=1";
      "-pix_fmt"; "yuv420p";
      "-movflags"; "+frag_keyframe+empty_moov+default_base_moof+separate_moof";
      "-frag_duration"; "0";
      "-f"; "mp4"; "pipe:1" ]
  in
  let fmp4_output = Ffmpeg.run_ffmpeg ~env encode_args input_data in
  let init_data, frames = split_fmp4_frames fmp4_output in
  Log.info (fun m -> m "iframe_stream: produced %d frames, init=%d bytes"
               (Array.length frames) (String.length init_data));
  let frame_duration_secs = 1.0 /. fps in
  { init_segment = init_data; frames; thumb_width = thumb_w;
    thumb_height = thumb_h; frame_duration_secs }
