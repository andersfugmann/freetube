open! Base

let v4 () =
  let raw = Mirage_crypto_rng.generate 16 in
  let bytes = Bytes.of_string raw in
  let set_byte i mask value =
    let current = Char.to_int (Bytes.get bytes i) in
    Bytes.set bytes i (Char.of_int_exn ((current land mask) lor value))
  in
  set_byte 6 0x0f 0x40;
  set_byte 8 0x3f 0x80;
  let hex = Ohex.encode (Bytes.to_string bytes) in
  Printf.sprintf "%s-%s-%s-%s-%s"
    (String.sub hex ~pos:0 ~len:8)
    (String.sub hex ~pos:8 ~len:4)
    (String.sub hex ~pos:12 ~len:4)
    (String.sub hex ~pos:16 ~len:4)
    (String.sub hex ~pos:20 ~len:12)

let v4_uppercase () = String.uppercase (v4 ())
