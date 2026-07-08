(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = string

let algorithm = "sha256"
let digest_size = 32
let hex_size = 64

external string : string -> t = "caml_spice_digest_sha256_string"

let to_raw_string digest = digest

let to_hex digest =
  let bytes = Bytes.create hex_size in
  for i = 0 to digest_size - 1 do
    let byte = Char.code (String.unsafe_get digest i) in
    let j = i * 2 in
    Bytes.unsafe_set bytes j (Char.Ascii.lower_hex_digit_of_int (byte lsr 4));
    Bytes.unsafe_set bytes (j + 1)
      (Char.Ascii.lower_hex_digit_of_int (byte land 0x0f))
  done;
  Bytes.unsafe_to_string bytes

let add_frame buffer text =
  Buffer.add_string buffer (string_of_int (String.length text));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer text

let key ~length ~domain parts =
  if length < 0 || length > hex_size then
    invalid_arg "Spice_digest.key: length must be between 0 and 64";
  if String.is_empty domain then invalid_arg "Spice_digest.key: empty domain";
  let buffer = Buffer.create 128 in
  add_frame buffer domain;
  List.iter (add_frame buffer) parts;
  String.take_first length (to_hex (string (Buffer.contents buffer)))

let equal = String.equal
let pp ppf t = Format.pp_print_string ppf (to_hex t)

module Identity = struct
  type t = { digest_hex : string; byte_length : int }

  let tag_size = String.length algorithm
  let digest_start = tag_size + 1
  let digest_end = digest_start + hex_size
  let length_start = digest_end + 1

  module Parse_error = struct
    type t = Invalid_identity

    let message = function
      | Invalid_identity ->
          "identity must be sha256:<64 lowercase hex>:<length>"

    let pp ppf error = Format.pp_print_string ppf (message error)
  end

  let of_contents contents =
    {
      digest_hex = to_hex (string contents);
      byte_length = String.length contents;
    }

  let to_string t =
    algorithm ^ ":" ^ t.digest_hex ^ ":" ^ string_of_int t.byte_length

  let is_lower_hex c = Char.Ascii.is_digit c || ('a' <= c && c <= 'f')

  let valid_digest_hex s =
    String.length s = hex_size && String.for_all is_lower_hex s

  let parse_byte_length s =
    let len = String.length s in
    if len = 0 || (len > 1 && Char.equal s.[0] '0') then
      Error Parse_error.Invalid_identity
    else
      let rec loop acc i =
        if i = len then Ok acc
        else
          let c = s.[i] in
          if not (Char.Ascii.is_digit c) then Error Parse_error.Invalid_identity
          else
            let digit = Char.Ascii.digit_to_int c in
            if acc > (max_int - digit) / 10 then
              Error Parse_error.Invalid_identity
            else loop ((acc * 10) + digit) (i + 1)
      in
      loop 0 0

  let of_string s =
    let len = String.length s in
    if
      len <= length_start
      || (not (Char.equal s.[tag_size] ':'))
      || (not (Char.equal s.[digest_end] ':'))
      || not (String.starts_with ~prefix:algorithm s)
    then Error Parse_error.Invalid_identity
    else
      let digest_hex = String.sub s digest_start hex_size in
      if not (valid_digest_hex digest_hex) then
        Error Parse_error.Invalid_identity
      else
        let byte_length = String.sub s length_start (len - length_start) in
        match parse_byte_length byte_length with
        | Error _ as error -> error
        | Ok byte_length -> Ok { digest_hex; byte_length }

  let digest_hex t = t.digest_hex
  let byte_length t = t.byte_length

  let equal a b =
    Int.equal a.byte_length b.byte_length
    && String.equal a.digest_hex b.digest_hex

  let pp ppf t = Format.pp_print_string ppf (to_string t)

  let jsont =
    Jsont.map ~kind:"Spice_digest.Identity"
      ~dec:(fun s ->
        match of_string s with
        | Ok t -> t
        | Error error ->
            Jsont.Error.msg Jsont.Meta.none (Parse_error.message error))
      ~enc:to_string Jsont.string
end
