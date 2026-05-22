open! Base
open Util

module Log = (val Log_src.src_log ~doc:"SRP-6a client for AirPlay pair-setup" Stdlib.__MODULE__)

type client_state = {
  username : string;
  password : string;
  a_private : string;
  a_public : string;
  salt : string;
  b_public : string;
  shared_key : string;
  client_proof : string;
}

let group_size = 384

let n_hex =
  "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
  ^ "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
  ^ "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
  ^ "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"
  ^ "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
  ^ "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
  ^ "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
  ^ "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33"
  ^ "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
  ^ "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864"
  ^ "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"
  ^ "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"

let n = Z.of_string_base 16 n_hex
let g = Z.of_int 5

let n_bytes = Ohex.decode n_hex

let normalize_mod value =
  let reduced = Z.erem value n in
  match Z.sign reduced with
  | -1 -> Z.add reduced n
  | _ -> reduced

let bytes_to_z value =
  match String.is_empty value with
  | true -> Z.zero
  | false -> Z.of_string_base 16 (Ohex.encode value)

let z_to_padded_bytes ~length value =
  let hex = Z.format "%x" value in
  let even_hex =
    match Int.( % ) (String.length hex) 2 with
    | 0 -> hex
    | _ -> "0" ^ hex
  in
  let value_bytes = Ohex.decode even_hex in
  match String.length value_bytes <= length with
  | false -> failwith "Integer is larger than the requested padded length"
  | true -> String.make (length - String.length value_bytes) '\000' ^ value_bytes

let pad value = z_to_padded_bytes ~length:group_size value

let sha512_concat values = values |> String.concat |> Crypto.sha512

let xor_strings left right =
  List.map2_exn (String.to_list left) (String.to_list right) ~f:(fun l r ->
    Char.of_int_exn (Char.to_int l lxor Char.to_int r))
  |> String.of_char_list

let k = bytes_to_z (sha512_concat [ n_bytes; pad g ])

let ensure_non_zero label value =
  match Z.equal value Z.zero with
  | true -> failwith (label ^ " must be non-zero")
  | false -> value

let generate_client ~password ~random_bytes =
  let a_private =
    match Int.equal (String.length random_bytes) 48 with
    | true -> random_bytes
    | false -> failwith "SRP client private value must be 48 bytes"
  in
  let a_public = Z.powm g (bytes_to_z a_private |> ensure_non_zero "client private value") n |> pad in
  {
    username = "Pair-Setup";
    password;
    a_private;
    a_public;
    salt = "";
    b_public = "";
    shared_key = "";
    client_proof = "";
  }

let strip_leading_zeros value =
  let length = String.length value in
  let rec find_first index =
    match index >= length with
    | true -> length - 1
    | false ->
        match Char.equal (String.get value index) '\000' with
        | true -> find_first (index + 1)
        | false -> index
  in
  let start = find_first 0 in
  String.sub value ~pos:start ~len:(length - start)

let process_server_challenge client_state ~salt ~b_public =
  let a = bytes_to_z client_state.a_private in
  let b = bytes_to_z b_public |> ensure_non_zero "server public key" in
  let b_padded = pad b in
  let b_trimmed = strip_leading_zeros b_padded in
  let username_password_hash = Crypto.sha512 (client_state.username ^ ":" ^ client_state.password) in
  let x = bytes_to_z (Crypto.sha512 (salt ^ username_password_hash)) in
  let u = bytes_to_z (sha512_concat [ client_state.a_public; b_padded ]) |> ensure_non_zero "scrambling parameter" in
  let gx = Z.powm g x n in
  let base = normalize_mod Z.(b - (k * gx)) in
  let exponent = Z.(a + (u * x)) in
  let shared_secret_int = Z.powm base exponent n in
  let shared_secret_minimal = strip_leading_zeros (pad shared_secret_int) in
  let shared_key = Crypto.sha512 shared_secret_minimal in
  let proof_prefix =
    xor_strings (Crypto.sha512 n_bytes) (Crypto.sha512 (String.of_char (Char.of_int_exn 0x05)))
  in
  let a_trimmed = strip_leading_zeros client_state.a_public in
  let client_proof =
    Crypto.sha512
      (proof_prefix
       ^ Crypto.sha512 client_state.username
       ^ salt
       ^ a_trimmed
       ^ b_trimmed
       ^ shared_key)
  in
  { client_state with salt; b_public = b_padded; shared_key; client_proof }

let verify_server_proof client_state ~server_proof =
  let a_trimmed = strip_leading_zeros client_state.a_public in
  String.equal
    (Crypto.sha512 (a_trimmed ^ client_state.client_proof ^ client_state.shared_key))
    server_proof

let%test_module "srp matches python srptools" = (module struct
  let a_private = Ohex.decode (String.concat (List.init 48 ~f:(fun _ -> "01")))
  let salt = Ohex.decode "0011223344556677889900aabbccddee"
  let b_hex =
    "400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003039"
  let b_public = Ohex.decode b_hex
  let expected_a_hex =
    "ad8058d499c91734e85afe4cac7eb1f52370e921e072ed35d2357e984aa63c54955766c143fea38c47952a5793c28d69a2b372048c7ae4020f47239555cffa7b03a745a875e16f94904f1a26b56afe407fc55ed435381d96f6d5b4142457e0a8c1a6ba84d2e60b4732cb45559d57f242a475cf34f0154565710075b004a551265708e1cec85a79884be15491dd89630d754010a6a0d35d2b88daf5353003609efd8530fe1a831241ce9226c1fbc5079febfd88371919c8d931b9a5f4024d951eea05ab73ff3acf82ec9d9f76a90557fd240c64784c8a64d7b060bb5371f9edd1474936162aae473ae441c5e52f834f2fa9d858cd720df9e0219d0cff23e3b6c184b6114e64cb0496d4e627ef92dbf9e3be14d57883088d3b3d8178242a622ee3d932248171a8a1bbec8f6013b9a6fca597122fd28a0bb7bfc6128835fad7c1c81fb0f5d72ea674e9679fee03d4b0ae03aafb68aeaec074b3e696039a9eb5aebd33f62548acbe3fc9d062ba4a77c57a8406b3d9dd27f8e60de789671946927ff4"
  let expected_k_hex =
    "cb62e0196a11887ad22d72d51491a496923e3ba9c496735fab9ff6f5c62d3350485af95408f3190c0a314803901b6a22028e9b4dc1524ed51d490f2faf407c15"
  let expected_m1_hex =
    "c3d0bfc8132ebc832bd7601b58d04e0cd0dfe596e4535c6db429719b90b7aa77f5a21cf0195ea48a47cbea86bebd8b8bf6f7ec3de999b9d8ca1352578ca8c948"

  let%test "A matches" =
    let client = generate_client ~password:"1234" ~random_bytes:a_private in
    String.equal (Ohex.encode client.a_public) expected_a_hex

  let%test "K matches" =
    let client =
      generate_client ~password:"1234" ~random_bytes:a_private
      |> process_server_challenge ~salt ~b_public
    in
    String.equal (Ohex.encode client.shared_key) expected_k_hex

  let%test "M1 matches" =
    let client =
      generate_client ~password:"1234" ~random_bytes:a_private
      |> process_server_challenge ~salt ~b_public
    in
    String.equal (Ohex.encode client.client_proof) expected_m1_hex
end)
