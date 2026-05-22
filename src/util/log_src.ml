open! Base

let src_log ?doc loc =
  let name =
    String.substr_replace_all ~pattern:"__" ~with_:"." loc
    |> String.lowercase
  in
  Logs.src_log (Logs.Src.create ?doc name)
