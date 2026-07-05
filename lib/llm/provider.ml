(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

type t = string

let is_rest c =
  Char.Ascii.is_lower c || Char.Ascii.is_digit c || Char.equal c '-'

let invalid message = invalid_arg' "Spice_llm.Provider" "make" message

let make id =
  if String.is_empty id then invalid "id must not be empty";
  if not (Char.Ascii.is_lower id.[0]) then
    invalid "id must start with a lowercase ASCII letter";
  String.iter
    (fun c ->
      if not (is_rest c) then
        invalid "id must contain only lowercase ASCII letters, digits, or '-'")
    id;
  id

let id t = t
let equal = String.equal
let compare = String.compare
let pp ppf t = Format.pp_print_string ppf t

let jsont =
  Jsont.map ~kind:"LLM provider"
    ~dec:(fun id -> decode_invalid_arg (fun () -> make id))
    ~enc:id Jsont.string
