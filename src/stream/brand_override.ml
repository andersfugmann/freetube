open! Base

(** Brand-override functor — rewrites the major brand of every
    [ftyp]/[styp] box at the front of init / segment payloads emitted
    by an fMP4 producer. Segments that do not begin with [ftyp]/[styp]
    (e.g. plain [moof+mdat] fragments from [Container_to_fmp4]) pass
    through untouched.

    Today the brand is always [isom]; introduce a parameter when a
    second target is needed. *)

let brand = Bmff.Isom

let leading_box_type s =
  let header = Bmff.parse_box_header s ~pos:0 in
  header.box_type

let maybe_rewrite s =
  match leading_box_type s with
  | "ftyp" | "styp" -> Bmff.set_major_brand s ~brand
  | _ -> s

module Make (M : Producer.S) : Producer.S with type kind = M.kind = struct
  type state =
    | Passthrough of M.state
    | Rewrite of { inner : M.state; mutable init_bytes : string option }
  type kind = M.kind
  let witness = M.witness

  let init ~env ~sw ~target =
    let inner, inner_shape = M.init ~env ~sw ~target in
    match Producer.Shape.container inner_shape with
    | Producer.Container.Mp4 ->
      Rewrite { inner; init_bytes = None }, inner_shape
    | _ ->
      Passthrough inner, inner_shape

  let info = function
    | Passthrough inner -> M.info inner
    | Rewrite { inner; _ } -> M.info inner

  let init_segment = function
    | Passthrough inner -> M.init_segment inner
    | Rewrite s ->
      match s.init_bytes with
      | Some bytes -> bytes
      | None ->
        let bytes = Bmff.set_major_brand (M.init_segment s.inner) ~brand in
        s.init_bytes <- Some bytes;
        bytes

  let max_segment_id = function
    | Passthrough inner -> M.max_segment_id inner
    | Rewrite { inner; _ } -> M.max_segment_id inner

  let close = function
    | Passthrough inner -> M.close inner
    | Rewrite { inner; _ } -> M.close inner

  let fetch_segment s ~id =
    match s with
    | Passthrough inner -> M.fetch_segment inner ~id
    | Rewrite { inner; _ } ->
      let seg = M.fetch_segment inner ~id in
      { seg with data = maybe_rewrite seg.data }
end

let%expect_test "set_major_brand on ftyp init" =
  let init = "\000\000\000\016ftypiso5\000\000\000\000" in
  let out = Bmff.set_major_brand init ~brand:Bmff.Isom in
  Stdlib.Printf.printf "%s\n" (String.sub out ~pos:8 ~len:4);
  [%expect {| isom |}]

let%expect_test "maybe_rewrite leaves moof alone" =
  let seg = "\000\000\000\010moof" in
  Stdlib.Printf.printf "%b\n" (String.equal seg (maybe_rewrite seg));
  [%expect {| true |}]
