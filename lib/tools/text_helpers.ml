(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Shared text classification and UTF-8 helpers for the file tools.

   These operate on already-decoded strings. They detect likely-binary content
   from NUL bytes and control-byte density, strip a trailing carriage return,
   find the longest valid UTF-8 prefix within a byte budget, and count logical
   lines. Read, write, search, and edit tools share them so binary detection,
   line-ending handling, and byte-cap repair stay identical across tools. *)

let is_text_control = function
  | '\t' | '\n' | '\r' | '\x0c' -> true
  | _ -> false

let is_control_byte c = Char.Ascii.is_control c && not (is_text_control c)

let looks_binary text =
  if String.contains text '\x00' then true
  else
    let controls = ref 0 in
    String.iter (fun c -> if is_control_byte c then incr controls) text;
    !controls * 10 > String.length text

let strip_trailing_cr text =
  if String.ends_with ~suffix:"\r" text then String.drop_last 1 text else text

let rec valid_utf8_prefix_from text index =
  if index <= 0 then ""
  else
    let prefix = String.sub text 0 index in
    if String.is_valid_utf_8 prefix then prefix
    else valid_utf8_prefix_from text (index - 1)

let valid_utf8_prefix text max_bytes =
  valid_utf8_prefix_from text (min (String.length text) max_bytes)

let logical_line_count text =
  if String.is_empty text then 0
  else
    let newlines = ref 0 in
    String.iter (fun c -> if Char.equal c '\n' then incr newlines) text;
    if Char.equal text.[String.length text - 1] '\n' then !newlines
    else !newlines + 1
