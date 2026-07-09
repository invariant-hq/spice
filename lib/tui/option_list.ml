(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type t = { selected : int; count : int }

let make ~count = { selected = 0; count = max 1 count }
let selected t = t.selected
let up t = { t with selected = (t.selected - 1 + t.count) mod t.count }
let down t = { t with selected = (t.selected + 1) mod t.count }
let jump n t = if n >= 1 && n <= t.count then { t with selected = n - 1 } else t

type checkbox = No_box | Checked | Unchecked

let row ~selected ?(checkbox = No_box) ~number ~label () =
  let style = if selected then Theme.accent else Theme.muted in
  let cursor = if selected then Theme.cursor else "  " in
  let box_seg =
    match checkbox with
    | No_box -> []
    | Checked -> [ seg style "[x] " ]
    | Unchecked -> [ seg Theme.muted "[ ] " ]
  in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ((seg style cursor :: box_seg)
    @ [ seg style (string_of_int number ^ ". "); label ])
