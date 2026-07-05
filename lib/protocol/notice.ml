(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn field =
  invalid_arg
    ("Spice_protocol.Notice." ^ fn ^ ": " ^ field ^ " must not be empty")

let reject_empty fn field value = if String.equal value "" then invalid fn field

module Severity = struct
  type t = Info | Warning | Error

  let to_string = function
    | Info -> "info"
    | Warning -> "warning"
    | Error -> "error"

  let compare = Stdlib.compare
  let equal a b = compare a b = 0
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

type t = {
  source : string;
  severity : Severity.t;
  title : string;
  body : string;
  key : string;
}

let make ~source ~severity ~title ~body ~key () =
  reject_empty "make" "source" source;
  reject_empty "make" "title" title;
  reject_empty "make" "body" body;
  reject_empty "make" "key" key;
  { source; severity; title; body; key }

let source t = t.source
let severity t = t.severity
let title t = t.title
let body t = t.body
let key t = t.key

let to_message t =
  Spice_llm.Message.developer
    (String.concat "\n"
       [
         "[spice notice]";
         "source: " ^ t.source;
         "severity: " ^ Severity.to_string t.severity;
         "title: " ^ t.title;
         "";
         t.body;
       ])
