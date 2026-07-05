(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

let min_cols = 110

(* The lowest width that still fits the 80-column transcript floor beside the
   28-column pane minimum and the 1-column rule (80 + 28 + 1 = 109). The pane
   persists down to here — the widest hysteresis band that never dips the
   transcript below its floor. *)
let keep_open_cols = 109

let presence ~cols ~was =
  if was then cols >= keep_open_cols else cols >= min_cols

(* Transcript-first (Thibaut's ruling): reserve 80 columns for the transcript and
   1 for the │ rule, give the pane what remains, clamped to [28, 40]. So the
   transcript never drops below 80 (the pane bottoms out at 28), and beyond a
   40-column pane all further width flows to the transcript. The 81 is the
   transcript floor (80) plus the rule (1). *)
let rule_cols = 1
let min_pane = 28
let max_pane = 40
let width ~cols = max min_pane (min max_pane (cols - 80 - rule_cols))

(* One column of padding between the │ rule and the content; none on the right,
   to leave the tenant its full budget. *)
let pad_left = 1
let content_width ~cols = max 1 (width ~cols - pad_left)

(* The transcript region is the terminal less the composer frame (top rule,
   input, bottom rule) and the footer — five rows of fixed chrome. The grant is
   approximate; [frame]'s hidden overflow is the guarantee against a push. *)
let region_chrome = 5
let content_rows ~rows = max 1 (rows - region_chrome)

let transcript_width ~cols ~open_ =
  if open_ then max 1 (cols - width ~cols - rule_cols) else max 1 cols

let hidden_overflow = { x = Overflow.Hidden; y = Overflow.Hidden }

let frame ~cols ~open_ ~left ~right =
  if not open_ then left
  else
    (* A [Column] container so the scrollport (which grows on the main axis, with
       [height = px 0] + [flex_grow], scrollport.ml) fills the region height; it
       flex-grows on the row's cross axis into [transcript_width]. *)
    let left_column =
      box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
        ~size:{ width = auto; height = pct 100 }
        [ left ]
    in
    (* The context & activity pane: a [Column] so the tenant's rows stack
       vertically. The │ rule is this column's left border, stretched to the region
       height; content is top-aligned and clipped so an over-budget tenant never
       grows the row. [border_box] keeps the outer width exactly [width + rule] so
       the transcript's [transcript_width] and this column tile the terminal
       without a gap. [right] may be empty — the region still shows, since presence
       is width. *)
    let pane_column =
      box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
        ~box_sizing:Box_sizing.Border_box ~overflow:hidden_overflow ~border:true
        ~border_sides:[ `Left ] ~border_color:Theme.color_rule
        ~padding:(padding_lrtb pad_left 0 0 0)
        ~size:{ width = px (width ~cols + rule_cols); height = pct 100 }
        right
    in
    (* Fill the shell's Column region exactly as the bare scrollport does
       ([flex_grow] + [height = px 0]) so opening the pane does not collapse the
       transcript. *)
    box ~key:"pane" ~flex_direction:Flex_direction.Row ~flex_grow:1.
      ~flex_shrink:1.
      ~size:{ width = pct 100; height = px 0 }
      [ left_column; pane_column ]
