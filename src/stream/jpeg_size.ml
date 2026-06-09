open! Base

let dimensions data =
  let len = String.length data in
  let rec scan pos =
    if pos + 1 >= len then None
    else if Char.equal (String.get data pos) '\xFF' then
      let marker = Char.to_int (String.get data (pos + 1)) in
      match marker with
      | 0xC0 | 0xC1 | 0xC2 | 0xC3 when pos + 9 < len ->
        let h = Char.to_int (String.get data (pos + 5)) lsl 8
                lor Char.to_int (String.get data (pos + 6)) in
        let w = Char.to_int (String.get data (pos + 7)) lsl 8
                lor Char.to_int (String.get data (pos + 8)) in
        Some (w, h)
      | 0xD8 | 0xD9 | 0x00 -> scan (pos + 2)
      | 0x01 | _ when marker >= 0xD0 && marker <= 0xD7 -> scan (pos + 2)
      | _ when pos + 3 < len ->
        let seg_len = Char.to_int (String.get data (pos + 2)) lsl 8
                      lor Char.to_int (String.get data (pos + 3)) in
        scan (pos + 2 + seg_len)
      | _ -> None
    else scan (pos + 1)
  in
  scan 0
