(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid_arg' fn message =
  invalid_arg ("Spice_sandbox.Error." ^ fn ^ ": " ^ message)

type kind = Unavailable | Invalid_request
type t = { kind : kind; message : string }

let kind_to_string = function
  | Unavailable -> "unavailable"
  | Invalid_request -> "invalid_request"

let make kind message =
  if String.equal message "" then invalid_arg' "make" "message is empty";
  { kind; message }

let unavailable message = make Unavailable message
let invalid_request message = make Invalid_request message
let message t = t.message

let equal a b =
  match (a.kind, b.kind) with
  | Unavailable, Unavailable | Invalid_request, Invalid_request ->
      String.equal a.message b.message
  | (Unavailable | Invalid_request), _ -> false

let pp ppf t = Format.pp_print_string ppf t.message

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let to_json t =
  json_obj
    [
      ("kind", Jsont.Json.string (kind_to_string t.kind));
      ("message", Jsont.Json.string t.message);
    ]
