open! Base
open Js_of_ocaml

(** Map a raw [chrome.cookies.getAll] JS array into [Api.Cookies.t list].
    yt-dlp wants the full netscape jar for [.youtube.com] — partial
    filtering breaks SAPISID-based auth. *)

let domain_youtube = ".youtube.com"

let of_js_cookie (c : Js.Unsafe.any) : Api.Cookies.t =
  let get k = Js.Unsafe.get c (Js.string k) in
  let str k = Js.to_string (Js.Unsafe.coerce (get k)) in
  let bool k = Js.to_bool (Js.Unsafe.coerce (get k)) in
  let opt_float k =
    let v = get k in
    match Js.to_string (Js.typeof (Js.Unsafe.coerce v)) with
    | "number" -> Some (Js.float_of_number (Js.Unsafe.coerce v))
    | _ -> None
  in
  let host_only =
    let v = get "hostOnly" in
    match Js.to_string (Js.typeof (Js.Unsafe.coerce v)) with
    | "boolean" -> Js.to_bool (Js.Unsafe.coerce v)
    | _ -> false
  in
  let expires =
    match opt_float "expirationDate" with
    | Some f -> Int.of_float f
    | None -> 0
  in
  {
    Api.Cookies.domain = str "domain";
    include_subdomains = not host_only;
    path = str "path";
    secure = bool "secure";
    expires;
    name = str "name";
    value = str "value";
  }

let fetch_youtube ~k =
  Chrome.Cookies_api.get_all ~domain:domain_youtube ~k:(fun arr ->
    let len = Js.Unsafe.get arr (Js.string "length") in
    let n = Int.of_float (Js.float_of_number (Js.Unsafe.coerce len)) in
    let out =
      List.init n ~f:(fun i ->
        of_js_cookie (Js.Unsafe.get arr i))
    in
    k out)
