open! Base

let ntp_epoch_offset = 2_208_988_800L

module Ntp_timestamp = struct
  type t = { seconds : int; fraction : int }

  let now ~clock =
    let value = Eio.Time.now clock in
    let secs_f = Float.round_down value in
    let frac_f = Float.( - ) value secs_f in
    let secs = Int64.( + ) (Float.to_int64 secs_f) ntp_epoch_offset in
    let frac = Float.to_int64 (Float.( * ) frac_f 4_294_967_296.0) in
    {
      seconds = Int64.to_int_trunc (Int64.bit_and secs 0xFFFFFFFFL);
      fraction = Int64.to_int_trunc (Int64.bit_and frac 0xFFFFFFFFL);
    }

  let read buf pos =
    let read_u32 p =
      let b0 = Char.to_int (Bytes.get buf p) in
      let b1 = Char.to_int (Bytes.get buf (p + 1)) in
      let b2 = Char.to_int (Bytes.get buf (p + 2)) in
      let b3 = Char.to_int (Bytes.get buf (p + 3)) in
      (b0 lsl 24) lor (b1 lsl 16) lor (b2 lsl 8) lor b3
    in
    { seconds = read_u32 pos; fraction = read_u32 (pos + 4) }

  let write buf pos t =
    let write_u32 p v =
      Bytes.set buf p (Char.of_int_exn ((v lsr 24) land 0xff));
      Bytes.set buf (p + 1) (Char.of_int_exn ((v lsr 16) land 0xff));
      Bytes.set buf (p + 2) (Char.of_int_exn ((v lsr 8) land 0xff));
      Bytes.set buf (p + 3) (Char.of_int_exn (v land 0xff))
    in
    write_u32 pos t.seconds;
    write_u32 (pos + 4) t.fraction
end

let read_u16_be buf pos =
  let b0 = Char.to_int (Bytes.get buf pos) in
  let b1 = Char.to_int (Bytes.get buf (pos + 1)) in
  (b0 lsl 8) lor b1

let write_u16_be buf pos value =
  Bytes.set buf pos (Char.of_int_exn ((value lsr 8) land 0xff));
  Bytes.set buf (pos + 1) (Char.of_int_exn (value land 0xff))

module Request = struct
  type t = {
    proto : int;
    msg_type : int;
    seq : int;
    origin : Ntp_timestamp.t;
  }

  let packet_size = 32

  let parse buf =
    match Bytes.length buf >= packet_size with
    | false -> None
    | true ->
        Some {
          proto = Char.to_int (Bytes.get buf 0);
          msg_type = Char.to_int (Bytes.get buf 1);
          seq = read_u16_be buf 2;
          origin = Ntp_timestamp.read buf 24;
        }
end

module Response = struct
  type t = {
    proto : int;
    seq : int;
    origin : Ntp_timestamp.t;
    receive : Ntp_timestamp.t;
    transmit : Ntp_timestamp.t;
  }

  let msg_type = 0xd3

  let encode t =
    let buf = Bytes.make 32 '\000' in
    Bytes.set buf 0 (Char.of_int_exn t.proto);
    Bytes.set buf 1 (Char.of_int_exn msg_type);
    write_u16_be buf 2 t.seq;
    Ntp_timestamp.write buf 8 t.origin;
    Ntp_timestamp.write buf 16 t.receive;
    Ntp_timestamp.write buf 24 t.transmit;
    buf
end

let%test "round trip" =
  let req_bytes = Bytes.make 32 '\000' in
  Bytes.set req_bytes 0 (Char.of_int_exn 0xd2);
  Bytes.set req_bytes 1 (Char.of_int_exn 0x01);
  write_u16_be req_bytes 2 42;
  Ntp_timestamp.write req_bytes 24 { seconds = 0x12345678; fraction = 0xabcdef01 };
  match Request.parse req_bytes with
  | None -> false
  | Some req ->
      let resp =
        Response.encode
          {
            proto = req.proto;
            seq = req.seq;
            origin = req.origin;
            receive = { seconds = 1; fraction = 2 };
            transmit = { seconds = 3; fraction = 4 };
          }
      in
      Char.to_int (Bytes.get resp 0) = 0xd2
      && Char.to_int (Bytes.get resp 1) = 0xd3
      && read_u16_be resp 2 = 42
      && (Ntp_timestamp.read resp 8).seconds = 0x12345678
      && (Ntp_timestamp.read resp 24).seconds = 3
