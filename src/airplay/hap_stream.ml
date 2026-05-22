open! Base
open Util

module Log = (val Log_src.src_log ~doc:"HAP-encrypted Eio flow wrapper" Stdlib.__MODULE__)

let max_outgoing_chunk = 1024

type state = {
  transport : Hap_transport.t;
  underlying : Eio.Flow.two_way_ty Eio.Resource.t;
  mutable read_buffer : string;
}

let create ~session_keys ~flow =
  {
    transport = Hap_transport.create ~session_keys;
    underlying = (flow :> Eio.Flow.two_way_ty Eio.Resource.t);
    read_buffer = "";
  }

let read_exact_from_underlying t n =
  match String.length t.read_buffer >= n with
  | true ->
      let out = String.sub t.read_buffer ~pos:0 ~len:n in
      t.read_buffer <- String.sub t.read_buffer ~pos:n ~len:(String.length t.read_buffer - n);
      out
  | false ->
      let buf = Cstruct.create 8192 in
      let buffer = Buffer.create (n + 256) in
      Buffer.add_string buffer t.read_buffer;
      t.read_buffer <- "";
      let rec loop () =
        match Buffer.length buffer >= n with
        | true -> ()
        | false ->
            let got = Eio.Flow.single_read t.underlying buf in
            Buffer.add_string buffer (Cstruct.to_string buf ~off:0 ~len:got);
            loop ()
      in
      loop ();
      let collected = Buffer.contents buffer in
      let out = String.sub collected ~pos:0 ~len:n in
      t.read_buffer <- String.sub collected ~pos:n ~len:(String.length collected - n);
      out

let read_frame t =
  let aad = read_exact_from_underlying t 2 in
  let plaintext_length =
    Char.to_int aad.[0] lor (Char.to_int aad.[1] lsl 8)
  in
  let rest = read_exact_from_underlying t (plaintext_length + 16) in
  match Hap_transport.decrypt_frame t.transport (aad ^ rest) with
  | None -> failwith "HAP frame decryption failed"
  | Some plaintext -> plaintext

let write t bytes =
  let len = String.length bytes in
  let rec loop offset =
    match offset >= len with
    | true -> ()
    | false ->
        let chunk = Int.min max_outgoing_chunk (len - offset) in
        let plaintext = String.sub bytes ~pos:offset ~len:chunk in
        let frame = Hap_transport.encrypt_frame t.transport plaintext in
        Eio.Flow.write t.underlying [ Cstruct.of_string frame ];
        loop (offset + chunk)
  in
  loop 0

type plaintext_buffer = {
  state : state;
  mutable pending : string;
}

let to_plaintext_buffer state = { state; pending = "" }

let read_plaintext_some buf =
  match String.is_empty buf.pending with
  | false ->
      let out = buf.pending in
      buf.pending <- "";
      out
  | true -> read_frame buf.state

let read_exact_plaintext buf n =
  let acc = Buffer.create n in
  Buffer.add_string acc buf.pending;
  buf.pending <- "";
  let rec loop () =
    match Buffer.length acc >= n with
    | true -> ()
    | false ->
        Buffer.add_string acc (read_frame buf.state);
        loop ()
  in
  loop ();
  let all = Buffer.contents acc in
  let out = String.sub all ~pos:0 ~len:n in
  buf.pending <- String.sub all ~pos:n ~len:(String.length all - n);
  out

let read_line buf =
  let rec loop acc =
    match String.index acc '\n' with
    | Some i ->
        let line = String.sub acc ~pos:0 ~len:i in
        let rest = String.sub acc ~pos:(i + 1) ~len:(String.length acc - i - 1) in
        buf.pending <- rest;
        let trimmed = String.rstrip ~drop:(Char.equal '\r') line in
        trimmed
    | None ->
        loop (acc ^ read_frame buf.state)
  in
  let pending = buf.pending in
  buf.pending <- "";
  loop pending
