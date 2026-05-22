open! Base

let () =
  let video_id =
    match Sys.get_argv () |> Array.to_list with
    | _ :: video_id :: _ -> video_id
    | _ -> failwith "usage: yt_probe <video_id>"
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun _sw ->
  let fetcher = Youtube.Fetcher.of_yt_dlp ~env ~cookies:[] ~video_id in
  let yt = Youtube.init fetcher in
  Youtube.Video_info.pp yt.video_info

