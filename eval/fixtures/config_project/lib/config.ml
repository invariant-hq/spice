(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let parse_line line =
  match String.split_on_char '=' line with
  | [ key; value ] -> Some (key, value)
  | _ -> None

let parse text =
  text |> String.split_on_char '\n' |> List.filter_map parse_line
