(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

(* The field names avoid [text]/[style], which [open Mosaic] already binds as
   the fields of {!Mosaic.span}. *)
type segment = { run : string; run_style : Ansi.Style.t option }

let segment ?style text = { run = text; run_style = style }

type row = segment list

type window = {
  start : int;
  length : int;
  hidden_above : int;
  hidden_below : int;
}

let max_visible = 5
let clamp lo hi x = if x < lo then lo else if x > hi then hi else x

let window ~total ~selected =
  if total <= 0 then
    { start = 0; length = 0; hidden_above = 0; hidden_below = 0 }
  else if total <= max_visible then
    { start = 0; length = total; hidden_above = 0; hidden_below = 0 }
  else
    let selected = clamp 0 (total - 1) selected in
    let start = clamp 0 (total - max_visible) (selected - (max_visible / 2)) in
    (* A seam slot stands in for the boundary item it replaces, so its count
       includes that hidden item: the first visible item sits one slot in. *)
    let hidden_above = if start > 0 then start + 1 else 0 in
    let hidden_below =
      if start + max_visible < total then total - (start + max_visible) + 1
      else 0
    in
    { start; length = max_visible; hidden_above; hidden_below }

let hidden_overflow = { x = Overflow.Hidden; y = Overflow.Hidden }

let cursor_segment selected =
  if selected then
    text ~style:Theme.accent ~wrap:`None ~flex_shrink:0. Theme.cursor
  else text ~wrap:`None ~flex_shrink:0. "  "

let item_row ~selected content =
  box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow
    ~size:{ width = pct 100; height = px 1 }
    (cursor_segment selected
    :: List.map
         (fun s -> text ?style:s.run_style ~wrap:`None ~flex_shrink:0. s.run)
         content)

(* The seam replaces a boundary slot with a muted [↑ N more] / [↓ N more] row,
   indented two spaces to sit under the cursor column (05-overlays-pickers.md). *)
let seam_row arrow n =
  text ~style:Theme.muted ~wrap:`None (Printf.sprintf "  %s %d more" arrow n)

let view ~selected rows =
  let total = List.length rows in
  if total = 0 then box ~flex_direction:Flex_direction.Column []
  else
    let selected = clamp 0 (total - 1) selected in
    let w = window ~total ~selected in
    let items = Array.of_list rows in
    let slots =
      List.init w.length (fun j ->
          if j = 0 && w.hidden_above > 0 then seam_row "↑" w.hidden_above
          else if j = w.length - 1 && w.hidden_below > 0 then
            seam_row "↓" w.hidden_below
          else
            let index = w.start + j in
            item_row ~selected:(index = selected) items.(index))
    in
    box ~flex_direction:Flex_direction.Column ~overflow:hidden_overflow
      ~size:{ width = pct 100; height = px w.length }
      slots

let note text_line = text ~style:Theme.muted ~wrap:`None ("  " ^ text_line)

let error text_line =
  text ~style:Theme.error ~wrap:`None (Theme.problem ^ text_line)
