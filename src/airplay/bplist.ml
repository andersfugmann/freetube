open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Binary plist encoder/decoder" Stdlib.__MODULE__)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Real of float
  | Data of string
  | String of string
  | Array of t list
  | Dict of (string * t) list

let dict items = Dict items
let str s = String s
let int_ i = Int i
let real_ f = Real f
let bool_ b = Bool b
let data b = Data b
let arr xs = Array xs

let rec flatten obj acc =
  let acc = obj :: acc in
  match obj with
  | Array items -> List.fold items ~init:acc ~f:(fun acc item -> flatten item acc)
  | Dict items ->
      List.fold items ~init:acc ~f:(fun acc (k, v) -> flatten v (flatten (String k) acc))
  | _ -> acc

let dedupe_objects objs =
  let table = Hashtbl.create (module String) in
  let key = function
    | Null -> "N"
    | Bool b -> Printf.sprintf "B%b" b
    | Int i -> Printf.sprintf "I%d" i
    | Real f -> Printf.sprintf "R%f" f
    | Data d -> "D" ^ d
    | String s -> "S" ^ s
    | Array _ | Dict _ -> Printf.sprintf "X%d" (Random.bits ())
  in
  let ordered =
    List.filter objs ~f:(fun obj ->
      let k = key obj in
      match obj with
      | Array _ | Dict _ -> true
      | _ ->
          match Hashtbl.mem table k with
          | true -> false
          | false -> Hashtbl.set table ~key:k ~data:(); true)
  in
  ordered, table, key

let int_size value =
  match value with
  | _ when value < 0 -> 8
  | _ when value < 0x100 -> 1
  | _ when value < 0x10000 -> 2
  | _ when value < 0x100000000 -> 4
  | _ -> 8

let pack_uint ~size value =
  let buf = Bytes.make size '\000' in
  let rec loop i v =
    match i < 0 with
    | true -> ()
    | false ->
        Bytes.set buf i (Char.of_int_exn (v land 0xff));
        loop (i - 1) (v lsr 8)
  in
  loop (size - 1) value;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:buf

let pack_int_object value =
  let size = int_size value in
  let marker =
    match size with
    | 1 -> 0x10
    | 2 -> 0x11
    | 4 -> 0x12
    | _ -> 0x13
  in
  String.of_char (Char.of_int_exn marker) ^ pack_uint ~size value

let pack_real_object value =
  let buf = Bytes.make 8 '\000' in
  let bits = Int64.bits_of_float value in
  for i = 0 to 7 do
    let shift = (7 - i) * 8 in
    Bytes.set buf i
      (Char.of_int_exn (Int64.to_int_exn
        (Int64.bit_and (Int64.shift_right_logical bits shift) 0xffL)))
  done;
  String.of_char '\035' ^ Bytes.unsafe_to_string ~no_mutation_while_string_reachable:buf

let pack_length ~marker_high length =
  match length < 15 with
  | true -> String.of_char (Char.of_int_exn ((marker_high lsl 4) lor length))
  | false ->
      String.of_char (Char.of_int_exn ((marker_high lsl 4) lor 0xf))
      ^ pack_int_object length

let pack_data value =
  pack_length ~marker_high:0x4 (String.length value) ^ value

let pack_string value =
  let is_ascii =
    String.for_all value ~f:(fun c -> Char.to_int c < 0x80)
  in
  match is_ascii with
  | true -> pack_length ~marker_high:0x5 (String.length value) ^ value
  | false ->
      let utf16 =
        Buffer.create (2 * String.length value)
      in
      String.iter value ~f:(fun c ->
        Buffer.add_char utf16 '\000';
        Buffer.add_char utf16 c);
      let bytes = Buffer.contents utf16 in
      pack_length ~marker_high:0x6 (String.length bytes / 2) ^ bytes

let encode obj =
  let objs = flatten obj [] |> List.rev in
  let unique, _table, key = dedupe_objects objs in
  let indexed = List.mapi unique ~f:(fun i o -> o, i) in
  let lookup =
    let table = Hashtbl.create (module String) in
    List.iter indexed ~f:(fun (o, i) ->
      match o with
      | Array _ | Dict _ -> ()
      | _ -> Hashtbl.set table ~key:(key o) ~data:i);
    table
  in
  let ref_index_of obj =
    match obj with
    | Array _ | Dict _ ->
        let i, _ =
          List.findi indexed ~f:(fun _ (o, _) -> phys_equal o obj)
          |> Option.value_exn
        in
        i
    | _ -> Hashtbl.find_exn lookup (key obj)
  in
  let count = List.length indexed in
  let ref_size = int_size (count - 1) in
  let encode_one (obj, _) =
    match obj with
    | Null -> "\000"
    | Bool false -> "\008"
    | Bool true -> "\009"
    | Int v -> pack_int_object v
    | Real v -> pack_real_object v
    | Data v -> pack_data v
    | String v -> pack_string v
    | Array items ->
        pack_length ~marker_high:0xa (List.length items)
        ^ String.concat (List.map items ~f:(fun item ->
            pack_uint ~size:ref_size (ref_index_of item)))
    | Dict pairs ->
        pack_length ~marker_high:0xd (List.length pairs)
        ^ String.concat (List.map pairs ~f:(fun (k, _) ->
            pack_uint ~size:ref_size (ref_index_of (String k))))
        ^ String.concat (List.map pairs ~f:(fun (_, v) ->
            pack_uint ~size:ref_size (ref_index_of v)))
  in
  let offsets, body =
    List.fold indexed ~init:([], Buffer.create 256) ~f:(fun (offsets, buf) item ->
      let offset = 8 + Buffer.length buf in
      Buffer.add_string buf (encode_one item);
      offset :: offsets, buf)
  in
  let offsets = List.rev offsets in
  let body_str = Buffer.contents body in
  let offset_table_offset = 8 + String.length body_str in
  let max_offset = offset_table_offset in
  let offset_size = int_size max_offset in
  let offset_table =
    List.map offsets ~f:(pack_uint ~size:offset_size) |> String.concat
  in
  let trailer = Bytes.make 32 '\000' in
  Bytes.set trailer 6 (Char.of_int_exn offset_size);
  Bytes.set trailer 7 (Char.of_int_exn ref_size);
  let set_be_uint64 ~at value =
    for i = 0 to 7 do
      let shift = (7 - i) * 8 in
      Bytes.set trailer (at + i)
        (Char.of_int_exn ((value lsr shift) land 0xff))
    done
  in
  set_be_uint64 ~at:8 count;
  set_be_uint64 ~at:24 offset_table_offset;
  "bplist00" ^ body_str ^ offset_table
  ^ Bytes.unsafe_to_string ~no_mutation_while_string_reachable:trailer

let decode payload =
  match String.is_prefix payload ~prefix:"bplist00" with
  | false -> failwith "missing bplist00 magic"
  | true ->
      let len = String.length payload in
      let trailer_offset = len - 32 in
      let trailer = String.sub payload ~pos:trailer_offset ~len:32 in
      let offset_size = Char.to_int trailer.[6] in
      let ref_size = Char.to_int trailer.[7] in
      let read_be ~at ~size =
        let rec loop i acc =
          match i >= size with
          | true -> acc
          | false -> loop (i + 1) ((acc lsl 8) lor Char.to_int trailer.[at + i])
        in
        loop 0 0
      in
      let count = read_be ~at:8 ~size:8 in
      let top_index = read_be ~at:16 ~size:8 in
      let offset_table_offset = read_be ~at:24 ~size:8 in
      let read_uint_at base ~size =
        let rec loop i acc =
          match i >= size with
          | true -> acc
          | false -> loop (i + 1) ((acc lsl 8) lor Char.to_int payload.[base + i])
        in
        loop 0 0
      in
      let object_offset index =
        read_uint_at (offset_table_offset + index * offset_size) ~size:offset_size
      in
      let rec parse_at offset =
        let marker = Char.to_int payload.[offset] in
        let high = (marker lsr 4) land 0xf in
        let low = marker land 0xf in
        let parse_count_and_data offset =
          match low <> 0xf with
          | true -> low, offset + 1
          | false ->
              let inner = Char.to_int payload.[offset + 1] in
              let int_size = 1 lsl (inner land 0xf) in
              let value = read_uint_at (offset + 2) ~size:int_size in
              value, offset + 2 + int_size
        in
        match high with
        | 0x0 ->
            (match low with
             | 0 -> Null
             | 8 -> Bool false
             | 9 -> Bool true
             | _ -> Null)
        | 0x1 ->
            let size = 1 lsl low in
            Int (read_uint_at (offset + 1) ~size)
        | 0x2 ->
            let size = 1 lsl low in
            (match size with
             | 8 ->
                 let bits =
                   let rec loop i acc =
                     match i >= 8 with
                     | true -> acc
                     | false ->
                         loop (i + 1)
                           (Int64.bit_or (Int64.shift_left acc 8)
                              (Int64.of_int (Char.to_int payload.[offset + 1 + i])))
                   in
                   loop 0 0L
                 in
                 Real (Int64.float_of_bits bits)
             | _ -> Real 0.0)
        | 0x4 ->
            let len, start = parse_count_and_data offset in
            Data (String.sub payload ~pos:start ~len)
        | 0x5 ->
            let len, start = parse_count_and_data offset in
            String (String.sub payload ~pos:start ~len)
        | 0x6 ->
            let len, start = parse_count_and_data offset in
            let buf = Buffer.create len in
            for i = 0 to len - 1 do
              Buffer.add_char buf payload.[start + 2 * i + 1]
            done;
            String (Buffer.contents buf)
        | 0xa ->
            let len, start = parse_count_and_data offset in
            let items =
              List.init len ~f:(fun i ->
                let idx = read_uint_at (start + i * ref_size) ~size:ref_size in
                parse_at (object_offset idx))
            in
            Array items
        | 0xd ->
            let len, start = parse_count_and_data offset in
            let keys =
              List.init len ~f:(fun i ->
                let idx = read_uint_at (start + i * ref_size) ~size:ref_size in
                match parse_at (object_offset idx) with
                | String s -> s
                | _ -> failwith "dict key is not string")
            in
            let values =
              List.init len ~f:(fun i ->
                let idx =
                  read_uint_at (start + (len + i) * ref_size) ~size:ref_size
                in
                parse_at (object_offset idx))
            in
            Dict (List.zip_exn keys values)
        | _ -> Printf.failwithf "unknown marker 0x%x" marker ()
      in
      ignore count;
      parse_at (object_offset top_index)

let find_dict obj =
  match obj with
  | Dict items -> items
  | _ -> failwith "not a dict"

let decode_assoc payload : (string * t) list option =
  match Result.try_with (fun () -> decode payload) with
  | Ok (Dict items) -> Some items
  | Ok _ | Error _ -> None

let find_string key obj =
  List.Assoc.find (find_dict obj) ~equal:String.equal key
  |> Option.bind ~f:(function String s -> Some s | _ -> None)

let find_int key obj =
  List.Assoc.find (find_dict obj) ~equal:String.equal key
  |> Option.bind ~f:(function Int i -> Some i | _ -> None)

let find_data key obj =
  List.Assoc.find (find_dict obj) ~equal:String.equal key
  |> Option.bind ~f:(function Data d -> Some d | _ -> None)

let find_array key obj =
  List.Assoc.find (find_dict obj) ~equal:String.equal key
  |> Option.bind ~f:(function Array xs -> Some xs | _ -> None)

let%test "roundtrip simple dict" =
  let obj = Dict [ "type", String "setRate"; "rate", Real 1.0 ] in
  let encoded = encode obj in
  let decoded = decode encoded in
  match find_string "type" decoded with
  | Some "setRate" -> true
  | _ -> false
