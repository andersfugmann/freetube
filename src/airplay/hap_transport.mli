type t

val create : session_keys:Pair_verify.session_keys -> t
val encrypt_frame : t -> string -> string
val decrypt_frame : t -> string -> string option
