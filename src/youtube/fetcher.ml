open! Base
open Util

module Log = (val Log_src.src_log ~doc:"yt-dlp fetcher" Stdlib.__MODULE__)

(** A fetcher produces a fresh streams JSON (the same shape as
    [yt-dlp -j] output) on each call. The two constructors below
    encapsulate the two ways FreeTube currently obtains it. *)

type t = unit -> Yojson.Safe.t

let of_yt_dlp ~env ~cookies ~video_id : t =
  let create_memfd ~name =
    let fd =
      Memfd.make_memfd ~name
        ~memfd_opts:(Memfd.make_memfd_opts ~allow_sealing:false ~cloexec:false ~huge_tlb_flag:None)
      |> Result.map_error ~f:Memfd.memfd_err_to_string
      |> Result.ok_or_failwith
    in
    (* Safe: on Linux [Unix.file_descr] is [int]; the memfd library returns
       its fd as a bare int with no typed conversion exposed. *)
    (Stdlib.Obj.magic fd : Unix.file_descr), Printf.sprintf "/proc/self/fd/%d" fd
  in
  let write_cookies fd =
    let cookiejar = Api.Cookies.to_netscape cookies in
    let len = String.length cookiejar in
    Eio_unix.run_in_systhread (fun () ->
      Unix.write_substring fd cookiejar 0 len |> ignore;
      Unix.lseek fd 0 Unix.SEEK_SET |> ignore);
    len
  in
  let cookie_fd, cookie_path = create_memfd ~name:"freetube-cookies" in
  let bytes = write_cookies cookie_fd in
  Log.info (fun m ->
    m "cookie memfd ready: video_id=%s cookies=%d path=%s bytes=%d"
      video_id (List.length cookies) cookie_path bytes);
  Stdlib.Gc.finalise (fun _ -> Unix.close cookie_fd) cookie_path;
  fun () -> Extract.extract_json ~timeout:10.0 ~env ~cookie_path video_id

let of_url ~env ~sw uri : t =
  fun () ->
    let client =
      Http_client.init
        ~max_conn_per_host:(Config.get ()).network.max_connections_per_host
        ~sw ~env ()
    in
    let response = Http_client.get client ~ip_version:`V4 ~oneshot:true uri in
    match response.status with
    | 200 -> Yojson.Safe.from_string response.body
    | code ->
        Printf.failwithf "fetch %s: HTTP %d" (Uri.to_string uri) code ()
