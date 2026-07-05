(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Duplicate_name of string
  | Unknown_tool of string
  | Invalid_input of { tool : string; diagnostic : string }

let message = function
  | Duplicate_name name -> "duplicate tool name: " ^ name
  | Unknown_tool "" -> "unknown tool"
  | Unknown_tool name -> "unknown tool: " ^ name
  | Invalid_input { tool; diagnostic } ->
      "invalid input for tool " ^ tool ^ ": " ^ diagnostic

let pp ppf t = Format.pp_print_string ppf (message t)
