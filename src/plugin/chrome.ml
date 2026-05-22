open! Base
open Js_of_ocaml

(** Thin bindings to the small subset of [chrome.*] APIs the plugin uses.
    The MV3 promise variants are used throughout (`Manifest V3` is
    Chrome 88+ / Edge 88+). All calls return `Promise`s.

    These bindings are intentionally minimal — we keep types as
    [Js.Unsafe.any] and decode/encode at the call site. *)

let chrome : Js.Unsafe.any = Js.Unsafe.pure_js_expr "globalThis.chrome"

let get_path path =
  List.fold path ~init:chrome ~f:(fun acc field ->
      Js.Unsafe.get acc (Js.string field))

(* Call [chrome.a.b.c(args)] preserving [this = chrome.a.b].
   This matters: chrome.* APIs throw "Illegal invocation" if the
   method is detached from its receiver. *)
let call path args =
  match List.rev path with
  | [] -> failwith "Chrome.call: empty path"
  | last :: rev_parents ->
      let parent = get_path (List.rev rev_parents) in
      Js.Unsafe.meth_call parent last args

let then_ (promise : Js.Unsafe.any) (k : Js.Unsafe.any -> unit) =
  let cb = Js.wrap_callback (fun v -> k v; Js.Unsafe.inject Js.undefined) in
  ignore (Js.Unsafe.meth_call promise "then" [| Js.Unsafe.inject cb |])

let catch (promise : Js.Unsafe.any) (k : Js.Unsafe.any -> unit) =
  let cb = Js.wrap_callback (fun v -> k v; Js.Unsafe.inject Js.undefined) in
  ignore (Js.Unsafe.meth_call promise "catch" [| Js.Unsafe.inject cb |])

let log msg = Console.console##log (Js.string msg)

(* ── chrome.storage.local ──────────────────────────────────────────── *)

module Storage = struct
  let get_string ~key ~default ~k =
    let q = Js.Unsafe.obj [| key, Js.Unsafe.inject (Js.string default) |] in
    let p = call [ "storage"; "local"; "get" ] [| Js.Unsafe.inject q |] in
    then_ p (fun v ->
      let raw = Js.Unsafe.get v (Js.string key) in
      let s = Js.to_string (Js.Unsafe.coerce raw) in
      k s)

  let set_string ~key ~value =
    let q = Js.Unsafe.obj [| key, Js.Unsafe.inject (Js.string value) |] in
    let _ = call [ "storage"; "local"; "set" ] [| Js.Unsafe.inject q |] in
    ()
end

(* ── chrome.cookies ────────────────────────────────────────────────── *)

module Cookies_api = struct
  (** [getAll {domain}] returns a JS array of cookie objects.
      Keep raw — caller maps into Api.Cookies.t. *)
  let get_all ~domain ~k =
    let q = Js.Unsafe.obj [| "domain", Js.Unsafe.inject (Js.string domain) |] in
    let p = call [ "cookies"; "getAll" ] [| Js.Unsafe.inject q |] in
    then_ p (fun arr -> k arr)
end

(* ── chrome.runtime messaging ──────────────────────────────────────── *)

module Runtime = struct
  let send_message ~msg ~k =
    let p = call [ "runtime"; "sendMessage" ] [| Js.Unsafe.inject msg |] in
    then_ p (fun v -> k v)

  type handler =
    Js.Unsafe.any -> Js.Unsafe.any -> (Js.Unsafe.any -> unit) -> bool

  let on_message (handler : handler) =
    let cb =
      Js.wrap_callback (fun msg sender send_response ->
        let respond v =
          ignore (Js.Unsafe.fun_call send_response [| Js.Unsafe.inject v |])
        in
        Js.bool (handler msg sender respond))
    in
    let add_listener =
      get_path [ "runtime"; "onMessage"; "addListener" ]
    in
    let on_msg = get_path [ "runtime"; "onMessage" ] in
    ignore (Js.Unsafe.meth_call on_msg "addListener" [| Js.Unsafe.inject cb |]);
    ignore add_listener
end

(* ── fetch ──────────────────────────────────────────────────────────── *)

module Fetch = struct
  let fetch_with_init ~init ~url ~k_ok ~k_err =
    let p =
      Js.Unsafe.fun_call
        (Js.Unsafe.pure_js_expr "fetch")
        [| Js.Unsafe.inject (Js.string url); Js.Unsafe.inject init |]
    in
    then_ p (fun resp ->
      let text_p = Js.Unsafe.meth_call resp "text" [||] in
      then_ text_p (fun body ->
        let status = Js.Unsafe.get resp (Js.string "status") in
        let status_int = Int.of_float (Js.float_of_number (Js.Unsafe.coerce status)) in
        let body_str = Js.to_string (Js.Unsafe.coerce body) in
        match status_int < 400 with
        | true -> k_ok body_str
        | false -> k_err status_int body_str));
    catch p (fun err ->
      let msg = Js.to_string (Js.Unsafe.coerce (Js.Unsafe.meth_call err "toString" [||])) in
      k_err 0 msg)

  let get ~url ~k_ok ~k_err =
    let init = Js.Unsafe.obj [|
      "method", Js.Unsafe.inject (Js.string "GET");
      "cache", Js.Unsafe.inject (Js.string "no-store");
    |] in
    fetch_with_init ~init ~url ~k_ok ~k_err

  let send ~meth ~url ~body ~k_ok ~k_err =
    let headers = Js.Unsafe.obj [|
      "Content-Type", Js.Unsafe.inject (Js.string "application/json")
    |] in
    let init = Js.Unsafe.obj [|
      "method", Js.Unsafe.inject (Js.string meth);
      "headers", Js.Unsafe.inject headers;
      "body", Js.Unsafe.inject (Js.string body);
      "cache", Js.Unsafe.inject (Js.string "no-store");
    |] in
    fetch_with_init ~init ~url ~k_ok ~k_err
end
