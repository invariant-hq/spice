(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_llm.Model" fn message

let is_component_char c =
  Char.Ascii.is_lower c || Char.Ascii.is_digit c || Char.equal c '-'

let check_api_id fn id =
  if String.is_empty id then invalid fn "id must not be empty";
  let len = String.length id in
  let rec component_start index =
    if index >= len then invalid fn "id has an empty component";
    if not (Char.Ascii.is_lower id.[index]) then
      invalid fn "id components must start with a lowercase ASCII letter";
    component_body (index + 1)
  and component_body index =
    if index >= len then ()
    else
      match id.[index] with
      | '.' -> component_start (index + 1)
      | c when is_component_char c -> component_body (index + 1)
      | _ ->
          invalid fn
            "id must contain only lowercase ASCII letters, digits, '-', or '.'"
  in
  component_start 0

module Api = struct
  type t = string

  let make id =
    check_api_id "Api.make" id;
    id

  let id t = t
  let equal = String.equal
  let compare = String.compare
  let pp = Format.pp_print_string

  let jsont =
    Jsont.map ~kind:"LLM model API"
      ~dec:(fun id -> decode_invalid_arg (fun () -> make id))
      ~enc:id Jsont.string
end

type t = { provider : Provider.t; api : Api.t; id : string }

let make ~provider ~api ~id =
  if String.is_empty id then invalid "make" "id must not be empty";
  { provider; api; id }

let provider t = t.provider
let api t = t.api
let id t = t.id

let equal a b =
  Provider.equal a.provider b.provider
  && Api.equal a.api b.api && String.equal a.id b.id

let compare a b =
  match Provider.compare a.provider b.provider with
  | 0 -> (
      match Api.compare a.api b.api with
      | 0 -> String.compare a.id b.id
      | order -> order)
  | order -> order

let pp ppf t =
  Format.fprintf ppf "%a/%a:%s" Provider.pp t.provider Api.pp t.api t.id

let jsont =
  let make provider api id =
    decode_invalid_arg (fun () -> make ~provider ~api ~id)
  in
  Jsont.Object.map ~kind:"LLM model" make
  |> Jsont.Object.mem "provider" Provider.jsont ~enc:provider
  |> Jsont.Object.mem "api" Api.jsont ~enc:api
  |> Jsont.Object.mem "id" Jsont.string ~enc:id
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
