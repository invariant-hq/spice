(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Digest = Spice_digest

let hex_string s = Digest.to_hex (Digest.string s)

let hex =
  testable ~pp:Format.pp_print_string ~equal:String.equal
    ~gen:(Gen.map hex_string (Gen.string_size (Gen.int_range 0 128) Gen.char))
    ()

let digest_hex_size = 64
let digest_raw_size = 32
let hex_digits = "0123456789abcdef"
let key_domain = "spice.digest.test.v1"

let hex_of_raw raw =
  let hex = Bytes.create (String.length raw * 2) in
  String.iteri
    (fun i c ->
      let byte = Char.code c in
      let j = i * 2 in
      Bytes.set hex j hex_digits.[byte lsr 4];
      Bytes.set hex (j + 1) hex_digits.[byte land 0x0f])
    raw;
  Bytes.unsafe_to_string hex

let expect_hex msg input expected = equal hex ~msg expected (hex_string input)
let all_bytes = String.init 256 (fun code -> Char.chr code)

let add_frame buffer text =
  Buffer.add_string buffer (string_of_int (String.length text));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer text

let framed_key_input ~domain parts =
  let buffer = Buffer.create 128 in
  add_frame buffer domain;
  List.iter (add_frame buffer) parts;
  Buffer.contents buffer

let expected_key ~domain parts = hex_string (framed_key_input ~domain parts)

let sha256_vectors () =
  let cases =
    [
      ( "empty",
        "",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" );
      ( "abc",
        "abc",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" );
      ( "The quick brown fox jumps over the lazy dog",
        "The quick brown fox jumps over the lazy dog",
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592" );
      ( "million a",
        String.make 1_000_000 'a',
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" );
    ]
  in
  List.iter (fun (msg, input, expected) -> expect_hex msg input expected) cases

let sha256_padding_boundaries () =
  let cases =
    [
      ( "55 bytes",
        String.make 55 'a',
        "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" );
      ( "56 bytes",
        String.make 56 'a',
        "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" );
      ( "57 bytes",
        String.make 57 'a',
        "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6" );
      ( "64 bytes",
        String.make 64 'a',
        "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" );
      ( "65 bytes",
        String.make 65 'a',
        "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0" );
    ]
  in
  List.iter (fun (msg, input, expected) -> expect_hex msg input expected) cases

let exact_bytes () =
  expect_hex "all byte values" all_bytes
    "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880";
  expect_hex "line endings are exact bytes" "line\r\nnext\n"
    "4edfe6fc73fd1015b423a47eb30b5ecb646706d5db6175d0f64f5af59eeac980";
  is_true ~msg:"embedded NUL changes digest"
    (not (Digest.equal (Digest.string "ab") (Digest.string "a\000b")))

let constants_are_consistent () =
  equal int ~msg:"hex digest size" digest_hex_size
    (String.length (hex_string ""));
  equal int ~msg:"raw digest size" digest_raw_size
    (String.length (Digest.to_raw_string (Digest.string "")))

let raw_digest_bytes () =
  let value = Digest.string "abc" in
  equal int ~msg:"raw digest size" digest_raw_size
    (String.length (Digest.to_raw_string value));
  equal hex ~msg:"raw digest bytes"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (hex_of_raw (Digest.to_raw_string value))

let hex_format_is_lowercase () =
  let text = hex_string "spice" in
  equal int ~msg:"hex length" digest_hex_size (String.length text);
  String.iter
    (fun c ->
      if not (('0' <= c && c <= '9') || ('a' <= c && c <= 'f')) then
        failf "non-lowercase-hex character: %C" c)
    text

let key () =
  let full = expected_key ~domain:key_domain [ "anchor" ] in
  equal string ~msg:"single part is hashed with its domain frame" full
    (Digest.key ~length:digest_hex_size ~domain:key_domain [ "anchor" ]);
  equal string ~msg:"zero-length key" ""
    (Digest.key ~length:0 ~domain:key_domain [ "anchor" ]);
  equal string ~msg:"key prefix" (String.take_first 8 full)
    (Digest.key ~length:8 ~domain:key_domain [ "anchor" ]);
  equal string ~msg:"empty parts are framed"
    (expected_key ~domain:key_domain [])
    (Digest.key ~length:digest_hex_size ~domain:key_domain []);
  equal string ~msg:"parts are length-framed"
    (expected_key ~domain:key_domain [ "a"; "b" ])
    (Digest.key ~length:digest_hex_size ~domain:key_domain [ "a"; "b" ]);
  is_true ~msg:"part boundaries are domain-separated"
    (not
       (String.equal
          (Digest.key ~length:digest_hex_size ~domain:key_domain [ "ab"; "c" ])
          (Digest.key ~length:digest_hex_size ~domain:key_domain
             [ "a"; "bc" ])));
  is_true ~msg:"empty part and no parts are distinct"
    (not
       (String.equal
          (Digest.key ~length:digest_hex_size ~domain:key_domain [])
          (Digest.key ~length:digest_hex_size ~domain:key_domain [ "" ])));
  is_true ~msg:"embedded NUL cannot erase a part boundary"
    (not
       (String.equal
          (Digest.key ~length:digest_hex_size ~domain:key_domain [ "a"; "b" ])
          (Digest.key ~length:digest_hex_size ~domain:key_domain [ "a\000b" ])));
  is_true ~msg:"embedded NUL cannot move a part boundary"
    (not
       (String.equal
          (Digest.key ~length:digest_hex_size ~domain:key_domain
             [ "a"; "b\000c" ])
          (Digest.key ~length:digest_hex_size ~domain:key_domain
             [ "a\000b"; "c" ])));
  is_true ~msg:"domains are separated"
    (not
       (String.equal
          (Digest.key ~length:digest_hex_size ~domain:"spice.digest.test.a"
             [ "same" ])
          (Digest.key ~length:digest_hex_size ~domain:"spice.digest.test.b"
             [ "same" ])));
  expect_invalid_arg
    ~expected:"Spice_digest.key: length must be between 0 and 64"
    "negative key length" (fun () ->
      Digest.key ~length:(-1) ~domain:key_domain [ "anchor" ]);
  expect_invalid_arg
    ~expected:"Spice_digest.key: length must be between 0 and 64"
    "oversized key length" (fun () ->
      Digest.key ~length:(digest_hex_size + 1) ~domain:key_domain [ "anchor" ]);
  expect_invalid_arg ~expected:"Spice_digest.key: empty domain" "empty domain"
    (fun () -> Digest.key ~length:8 ~domain:"" [ "anchor" ])

let comparison_and_formatting () =
  let a = Digest.string "a" in
  let b = Digest.string "b" in
  is_true ~msg:"equal is reflexive" (Digest.equal a a);
  is_true ~msg:"different digests are not equal" (not (Digest.equal a b));
  equal string ~msg:"pp formats hex" (Digest.to_hex a)
    (Format.asprintf "%a" Digest.pp a)

let identity_round_trip () =
  let contents = "hello\000spice\n" in
  let identity = Digest.Identity.of_contents contents in
  let text = Digest.Identity.to_string identity in
  let parsed =
    match Digest.Identity.of_string text with
    | Ok parsed -> parsed
    | Error error ->
        failf "identity did not parse: %a" Digest.Identity.Parse_error.pp error
  in
  equal string ~msg:"identity text"
    ("sha256:" ^ hex_string contents ^ ":"
    ^ string_of_int (String.length contents))
    text;
  equal string ~msg:"identity digest hex" (hex_string contents)
    (Digest.Identity.digest_hex identity);
  equal int ~msg:"identity byte length" (String.length contents)
    (Digest.Identity.byte_length identity);
  is_true ~msg:"identity equal after parsing"
    (Digest.Identity.equal identity parsed);
  equal string ~msg:"identity pp" text
    (Format.asprintf "%a" Digest.Identity.pp identity)

let identity_zero_length () =
  let identity = Digest.Identity.of_contents "" in
  equal string ~msg:"zero length identity"
    ("sha256:" ^ hex_string "" ^ ":0")
    (Digest.Identity.to_string identity);
  match Digest.Identity.of_string (Digest.Identity.to_string identity) with
  | Ok parsed ->
      equal int ~msg:"parsed zero byte length" 0
        (Digest.Identity.byte_length parsed)
  | Error error ->
      failf "zero length identity did not parse: %a"
        Digest.Identity.Parse_error.pp error

let identity_parser_rejects_noncanonical_forms () =
  let hex = hex_string "seen" in
  let uppercase_hex = String.uppercase_ascii hex in
  let oversized_length = string_of_int max_int ^ "0" in
  let max_length_identity = "sha256:" ^ hex ^ ":" ^ string_of_int max_int in
  let cases =
    [
      ("empty", "");
      ("opaque string", "seen");
      ("missing length", "sha256:" ^ hex);
      ("extra field", "sha256:" ^ hex ^ ":4:extra");
      ("wrong algorithm", "sha512:" ^ hex ^ ":4");
      ("short hex", "sha256:" ^ String.take_first 63 hex ^ ":4");
      ("uppercase hex", "sha256:" ^ uppercase_hex ^ ":4");
      ("non-hex digest", "sha256:" ^ String.take_first 63 hex ^ "g:4");
      ("empty length", "sha256:" ^ hex ^ ":");
      ("signed length", "sha256:" ^ hex ^ ":+4");
      ("negative length", "sha256:" ^ hex ^ ":-4");
      ("leading zero length", "sha256:" ^ hex ^ ":04");
      ("overflow length", "sha256:" ^ hex ^ ":" ^ oversized_length);
    ]
  in
  List.iter
    (fun (msg, text) ->
      match Digest.Identity.of_string text with
      | Ok identity -> failf "%s parsed as %a" msg Digest.Identity.pp identity
      | Error Digest.Identity.Parse_error.Invalid_identity -> ())
    cases;
  (match Digest.Identity.of_string max_length_identity with
  | Ok identity ->
      equal int ~msg:"max int byte length" max_int
        (Digest.Identity.byte_length identity)
  | Error error ->
      failf "max int length did not parse: %a" Digest.Identity.Parse_error.pp
        error);
  equal string ~msg:"parse error message"
    "identity must be sha256:<64 lowercase hex>:<length>"
    (Digest.Identity.Parse_error.message
       Digest.Identity.Parse_error.Invalid_identity);
  equal string ~msg:"parse error pp"
    "identity must be sha256:<64 lowercase hex>:<length>"
    (Format.asprintf "%a" Digest.Identity.Parse_error.pp
       Digest.Identity.Parse_error.Invalid_identity)

let key_input_gen =
  Gen.bind (Gen.int_range 0 digest_hex_size) (fun length ->
      Gen.map
        (fun parts -> (length, parts))
        (Gen.list_size (Gen.int_range 0 4)
           (Gen.string_size (Gen.int_range 0 8) Gen.char)))

let key_input =
  testable
    ~pp:(fun ppf (length, parts) ->
      Format.fprintf ppf "(length=%d, [ %s ])" length
        (String.concat "; " (List.map (Printf.sprintf "%S") parts)))
    ~gen:key_input_gen ()

let generated_key_is_lowercase_hex_of_length (length, parts) =
  let key = Digest.key ~length ~domain:key_domain parts in
  equal int ~msg:"key has exactly length characters" length (String.length key);
  String.iter
    (fun c ->
      if not (('0' <= c && c <= '9') || ('a' <= c && c <= 'f')) then
        failf "non-lowercase-hex character in key: %C" c)
    key

let generated_key_matches_framing (_length, parts) =
  equal string ~msg:"full key is the digest of framed domain and parts"
    (expected_key ~domain:key_domain parts)
    (Digest.key ~length:digest_hex_size ~domain:key_domain parts)

let generated_hex_round_trips text =
  let value = Digest.string text in
  equal hex ~msg:"generated hex matches to_hex" (hex_string text)
    (Digest.to_hex value);
  equal int ~msg:"generated hex size" digest_hex_size
    (String.length (Digest.to_hex value))

let () =
  run "spice.digest"
    [
      test "matches SHA-256 vectors" sha256_vectors;
      test "handles SHA-256 padding boundaries" sha256_padding_boundaries;
      test "digests exact bytes" exact_bytes;
      test "has consistent constants" constants_are_consistent;
      test "exposes raw digest bytes" raw_digest_bytes;
      test "formats lowercase hex" hex_format_is_lowercase;
      test "derives keys from parts" key;
      test "compares and formats digests" comparison_and_formatting;
      test "round-trips content identities" identity_round_trip;
      test "round-trips zero-length identities" identity_zero_length;
      test "rejects noncanonical identities"
        identity_parser_rejects_noncanonical_forms;
      prop' "generated hex is stable" string generated_hex_round_trips;
      prop' "keys are lowercase hex of the requested length" key_input
        generated_key_is_lowercase_hex_of_length;
      prop' "full keys equal the digest of framed domain and parts" key_input
        generated_key_matches_framing;
    ]
