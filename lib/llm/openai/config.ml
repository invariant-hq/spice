(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  base_url : string option;
  organization : string option;
  project : string option;
  headers : (string * string) list;
  timeout_s : float;
  max_retries : int option;
}

let invalid message = invalid_arg ("Spice_llm_openai.Config.make: " ^ message)

let contains_newline s =
  String.exists (function '\n' | '\r' -> true | _ -> false) s

let check_optional field = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid (field ^ " must not be empty");
      if contains_newline value then
        invalid (field ^ " must not contain newline")

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

let check_headers headers =
  List.iter
    (fun (name, value) ->
      if String.is_empty name then invalid "header name must not be empty";
      if contains_newline name then
        invalid "header name must not contain newline";
      if contains_newline value then
        invalid ("header " ^ name ^ " value must not contain newline"))
    headers

let make ?base_url ?organization ?project ?(headers = [])
    ?(timeout_s = default_timeout_s) ?max_retries () =
  check_optional "base_url" base_url;
  check_optional "organization" organization;
  check_optional "project" project;
  check_headers headers;
  check_timeout_s timeout_s;
  check_max_retries max_retries;
  {
    base_url = normalize_base_url base_url;
    organization;
    project;
    headers;
    timeout_s;
    max_retries;
  }

let default = make ()
let base_url t = t.base_url
let organization t = t.organization
let project t = t.project
let headers t = t.headers
let timeout_s t = t.timeout_s
let max_retries t = t.max_retries
