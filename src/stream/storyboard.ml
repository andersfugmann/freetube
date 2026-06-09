open! Base
open Util

module Log = (val Log_src.src_log ~doc:"iframe stream from storyboard sprites" Stdlib.__MODULE__)

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

let fetch_sprite client url =
  let uri = Uri.of_string url in
  let resp = Http_client.get client ~ip_version:`V6 uri in
  resp.body

let init ~env ~sw ~client ~(storyboard : Youtube.Video_info.Storyboard.t) =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let fragments = Array.of_list storyboard.fragments in
    let columns = storyboard.columns in
    let rows = storyboard.rows in
    let thumb_w = storyboard.width in
    let thumb_h = storyboard.height in
    let count = Array.length fragments in
    let expected_w = thumb_w * columns in
    let expected_h = thumb_h * rows in
    let interval = 10.0 in
    let offset = interval /. 2.0 in
    (* Fetch and filter sprites, prefetching in a background fiber *)
    let cache = Hashtbl.create (module Int) in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Array.iteri fragments ~f:(fun i frag ->
        match Hashtbl.mem cache i with
        | true -> ()
        | false ->
          let p, resolver = Eio.Promise.create () in
          Hashtbl.set cache ~key:i ~data:p;
          match fetch_sprite client frag.url with
          | data ->
            Eio.Promise.resolve_ok resolver data;
            Log.debug (fun m -> m "prefetched sprite %d/%d" (i + 1) count)
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception exn ->
            Eio.Promise.resolve_error resolver exn;
            Log.warn (fun m -> m "sprite prefetch %d failed: %s" i (Exn.to_string exn)));
      `Stop_daemon);
    let fetch_cached id =
      match Hashtbl.find cache id with
      | Some p -> Eio.Promise.await_exn p
      | None ->
        let p, resolver = Eio.Promise.create () in
        Hashtbl.set cache ~key:id ~data:p;
        let data = fetch_sprite client fragments.(id).url in
        Eio.Promise.resolve_ok resolver data;
        data
    in
    let sprite_buf = Buffer.create (count * 50_000) in
    let included = ref 0 in
    for frag_idx = 0 to count - 1 do
      let sprite_data = fetch_cached frag_idx in
      match Jpeg_size.dimensions sprite_data with
      | Some (w, h) when w = expected_w && h = expected_h ->
        Buffer.add_string sprite_buf sprite_data;
        Int.incr included
      | Some (w, h) ->
        Log.info (fun m -> m "skipping sprite %d (size %dx%d, expected %dx%d)"
                     frag_idx w h expected_w expected_h)
      | None ->
        Log.warn (fun m -> m "skipping sprite %d (cannot read dimensions)" frag_idx)
    done;
    let n_sprites = !included in
    let input_data = Buffer.contents sprite_buf in
    Log.info (fun m -> m "encoding %d/%d sprites (%dx%d grid, interval=%.1fs offset=%.1fs)"
                 n_sprites count columns rows interval offset);
    let vf = Printf.sprintf "untile=%dx%d,settb=AVTB,setpts=(N*%f+%f)/TB"
        columns rows interval offset in
    let encode_args =
      [ "-f"; "image2pipe"; "-framerate"; "1"; "-i"; "pipe:0";
        "-vf"; vf;
        "-c:v"; "libx264"; "-preset"; "fast"; "-crf"; "18";
        "-tune"; "stillimage";
        "-x264-params"; "keyint=1:min-keyint=1";
        "-pix_fmt"; "yuv420p"; "-fps_mode"; "passthrough";
        "-movflags"; "+frag_keyframe+empty_moov+default_base_moof+separate_moof";
        "-frag_duration"; "0";
        "-f"; "mp4"; "pipe:1" ]
    in
    let fmp4_output = Ffmpeg.run_ffmpeg ~env encode_args input_data in
    let init_end, frame_ranges = index_fmp4 fmp4_output in
    Log.info (fun m -> m "produced %d frames, init=%d bytes, total=%d bytes"
                 (Array.length frame_ranges) init_end (String.length fmp4_output));
    { data = fmp4_output; init_end; frame_ranges;
      thumb_width = thumb_w; thumb_height = thumb_h;
      frame_duration_secs = interval }
  )
