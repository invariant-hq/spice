(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

let default_style = Ansi.Style.default

(* The lockup is 23 columns. A fixed-width block holds both rows left-aligned so
   they stay registered when the animated frame changes row 1's trailing width,
   and the whole block is centered as a unit (12-home.md §Layout). *)
let lockup_width = 23
let blank_row = box ~size:{ width = pct 100; height = px 1 } []

let lockup_block rows =
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~size:{ width = px lockup_width; height = auto }
    (List.map
       (fun row ->
         box ~size:{ width = pct 100; height = px 1 } [ seg Theme.accent row ])
       rows)

(* The stage centers the brand: the lockup, then one facts line — version muted,
   model default, no cwd (the footer carries the cwd). The ["pro plan"] fact is
   omitted: there is no host plan concept yet. *)
let home (snapshot : Snapshot.t) ~rows =
  let facts =
    box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
      ~size:{ width = auto; height = px 1 }
      [
        seg Theme.muted snapshot.Snapshot.version;
        seg Theme.muted Theme.separator;
        seg default_style (Snapshot.model_line snapshot);
      ]
  in
  box ~flex_direction:Flex_direction.Column ~align_items:Align.Center
    ~flex_shrink:0.
    ~size:{ width = pct 100; height = auto }
    [ lockup_block rows; blank_row; facts ]

(* The hanging fact lines indent to the record's text column (04-header-footer.md
   §1); this is the historical heap+space indent, preserved so the labels stay
   registered under the lockup. *)
let record_indent = "      "

(* The right column opens two columns past the lockup block, matching the home
   lockup's gap to its facts (the mock in 04-header-footer.md §Banner record). *)
let record_gap = 2

(* The record colors a bypassed posture ["never ask"] error, other non-default
   postures muted (04-header-footer.md §1, fact_style). *)
let permission_style label =
  if String.equal label "never ask" then Theme.error else Theme.muted

(* Display width in columns: one per UTF-8 scalar value (a continuation byte
   begins [0b10……]). *)
let display_width s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

let ellipsis = "…"

(* Keep the first [width] display columns of [s], appending an ellipsis when it
   overflows. Byte-scans by scalar value so a multibyte glyph is never split.
   Pre-truncation in OCaml, not [truncate:true]: Mosaic's flex truncate measures
   at the text's previous layout width (mosaic_flex_truncate_quirk). *)
let truncate_columns ~width s =
  if display_width s <= width || width <= 0 then s
  else
    let keep = width - 1 in
    let buf = Buffer.create (String.length s) in
    let cols = ref 0 in
    (try
       String.iter
         (fun c ->
           if Char.code c land 0xC0 <> 0x80 then begin
             if !cols >= keep then raise Exit;
             incr cols
           end;
           Buffer.add_char buf c)
         s
     with Exit -> ());
    Buffer.contents buf ^ ellipsis

let record_row style s =
  box ~size:{ width = auto; height = px 1 } [ seg style s ]

(* The transcript record (04-header-footer.md §Banner record): the two-row frozen
   lockup in {!Theme.accent} on the left, and a top-aligned right column with the
   version and model on row 1 and the home-relative cwd on row 2, both
   {!Theme.muted}. Non-default permission/sandbox postures hang below. The right
   column's facts and cwd pre-truncate to their column budget so a narrow terminal
   never wraps the record. *)
(* The record floats inside a one-cell margin on every side (a blank row above
   and below, one column of inset left and right), so it reads as a framed header
   rather than butting against the terminal edge. The right-column budget loses
   the two inset columns. *)
let record_margin = 1

let record (snapshot : Snapshot.t) ~width =
  let inner_width = width - (2 * record_margin) in
  let right_width = max 8 (inner_width - lockup_width - record_gap) in
  let facts =
    truncate_columns ~width:right_width
      (snapshot.Snapshot.version ^ Theme.separator
      ^ Snapshot.model_line snapshot)
  in
  let cwd =
    Path_display.middle_truncate ~width:right_width
      (Path_display.home_relative snapshot.Snapshot.cwd)
  in
  let right =
    box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
      ~size:{ width = auto; height = auto }
      [ record_row Theme.muted facts; record_row Theme.muted cwd ]
  in
  let head =
    box ~flex_direction:Flex_direction.Row
      ~size:{ width = pct 100; height = auto }
      [
        lockup_block Theme.lockup;
        box ~size:{ width = px record_gap; height = auto } [];
        right;
      ]
  in
  let hanging label_of style_of = function
    | None -> []
    | Some value ->
        [
          text ~style:(style_of value) ~wrap:`None
            (record_indent ^ label_of value);
        ]
  in
  box ~flex_direction:Flex_direction.Column ~padding:(padding record_margin)
    ~size:{ width = pct 100; height = auto }
    (head
     :: hanging
          (fun label -> "permission: " ^ label)
          permission_style snapshot.Snapshot.permission
    @ hanging
        (fun label -> "sandbox: " ^ label)
        (fun _ -> Theme.warning)
        snapshot.Snapshot.sandbox)
