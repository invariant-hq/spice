(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  base_url : string option;
  timeout_s : float;
  max_retries : int option;
}

let invalid message = invalid_arg ("Spice_llm_google.Config.make: " ^ message)

let contains_newline s =
  String.exists (function '\n' | '\r' -> true | _ -> false) s

let check_base_url = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid "base_url must not be empty";
      if contains_newline value then invalid "base_url must not contain newline"

let trim_trailing_slash = String.drop_last_while (Char.equal '/')

let normalize_base_url = function
  | None -> None
  | Some value ->
      let value = trim_trailing_slash value in
      if String.is_empty value then invalid "base_url must not be only slashes";
      Some value

let default_timeout_s = 600.

let check_timeout_s value =
  if (not (Float.is_finite value)) || value <= 0. then
    invalid "timeout_s must be positive and finite"

let check_max_retries = function
  | None -> ()
  | Some value -> if value < 0 then invalid "max_retries must be non-negative"

let make ?base_url ?(timeout_s = default_timeout_s) ?max_retries () =
  check_base_url base_url;
  check_timeout_s timeout_s;
  check_max_retries max_retries;
  { base_url = normalize_base_url base_url; timeout_s; max_retries }

let default = make ()
let base_url t = t.base_url
let timeout_s t = t.timeout_s
let max_retries t = t.max_retries
