open! Base

module Video_info = Video_info
module Cookies = Api.Cookies
module Extract = Extract
module Fetcher = Fetcher

type t = {
  fetcher    : Fetcher.t;
  video_info : Video_info.t;
}

let video_info_of_json json =
  Video_info.of_yojson json |> Result.ok_or_failwith

let init fetcher =
  let video_info = fetcher () |> video_info_of_json in
  { fetcher; video_info }

let refresh t stream =
  let stream_id = stream.Video_info.Stream.format_id in
  let find_stream streams =
    List.find_exn streams ~f:(fun { Video_info.Stream.format_id; _ } ->
        String.equal stream_id format_id)
  in
  match find_stream t.video_info.streams with
  | { url; _ } when String.equal url stream.url -> t, stream
  | _ ->
      let video_info = t.fetcher () |> video_info_of_json in
      let t = { t with video_info } in
      t, find_stream t.video_info.streams
