(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The CR compose dialog (11-review.md §CR compose): a plain filled ~60-column
   box — muted title, a painted single-line draft with an accent cursor glyph,
   and an error line — no rules or border. The panel floats it over the center of
   the dimmed panes. The draft carries the CR grammar itself; parsing happens on
   submit (in the component), and parse or write problems render as a [!] line
   under the input with the draft preserved.

   The input is app-owned and painted, not a native widget: the review screen
   owns its keyboard, so the component folds keys into the draft via [append] and
   [backspace] and this module paints the insertion point. *)

type target =
  | Add of { path : Spice_path.Rel.t; line : int }
  | Edit of { occurrence : Spice_cr.Occurrence.t; ordinal : int }
  | Resolve of { occurrence : Spice_cr.Occurrence.t; ordinal : int }

type t = { target : target; draft : string; problem : string option }

let make ~target ~draft = { target; draft; problem = None }
let target t = t.target
let draft t = t.draft
let with_problem t problem = { t with problem = Some problem }
let with_draft t draft = { t with draft; problem = None }
let append t s = { t with draft = t.draft ^ s; problem = None }

(* Delete a whole trailing UTF-8 codepoint, never half of one: step back over
   continuation bytes (10xxxxxx). *)
let backspace t =
  let s = t.draft in
  let n = String.length s in
  if n = 0 then { t with problem = None }
  else
    let rec back i =
      if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then back (i - 1) else i
    in
    let cut = back (n - 1) in
    { t with draft = String.sub s 0 cut; problem = None }

let occurrence_location occ =
  Printf.sprintf "%s:%d"
    (Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
    (Spice_cr.Occurrence.line occ)

(* [Edit]/[Resolve] carry the occurrence itself, so the affordance reads its
   location directly rather than re-resolving a live index that a background
   refresh may have shifted onto a different CR. *)
let affordance t _review =
  match t.target with
  | Add { path; line } ->
      Printf.sprintf "CR on %s:%d" (Spice_path.Rel.to_string path) line
  | Edit { occurrence; _ } -> "edit CR on " ^ occurrence_location occurrence
  | Resolve { occurrence; _ } ->
      "resolve CR on " ^ occurrence_location occurrence

let line ?style text = Mosaic.text ?style ~wrap:`None ~flex_shrink:0. text
let dialog_width = 60

(* The painted insertion point: an accent bar the eye reads as a cursor. It is a
   glyph, not the terminal's hardware cursor — the review screen owns its
   keyboard and delivers no key to a native widget. *)
let cursor_glyph = "▏"

(* The input row: the draft plus the painted cursor, or a faint placeholder plus
   the cursor when empty. *)
let input_row draft =
  if String.equal draft "" then
    Mosaic.box ~flex_direction:Mosaic.Flex_direction.Row
      ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px 1 }
      [
        line ~style:Style.accent cursor_glyph;
        line ~style:Style.faint "handle: comment";
      ]
  else
    line
      ~style:(Mosaic.Ansi.Style.make ~fg:Mosaic.Ansi.Color.white ())
      (draft ^ cursor_glyph)

(* A plain filled dialog: an opaque background with padding, a muted title, and
   the painted input line — no rules or border, the fill and padding are the
   frame. An error line shows below on a parse/write failure. *)
let view ?width:_ t review =
  let problem =
    match t.problem with
    | None -> []
    | Some message -> [ line ~style:Style.error ("! " ^ message) ]
  in
  let rows =
    [ line ~style:Style.muted (affordance t review); input_row t.draft ]
    @ problem
  in
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Column ~flex_shrink:0.
    ~box_sizing:Mosaic.Box_sizing.Border_box ~background:Style.color_overlay
    ~padding:(Mosaic.padding_lrtb 2 2 1 1)
    ~size:
      {
        Mosaic.width = Mosaic.px dialog_width;
        height = Mosaic.px (List.length rows + 2);
      }
    rows

(* The dialog's row count (title + input + padding, plus an error line), so the
   panel reserves exactly that much space at the diff-pane bottom. *)
let height t = 4 + match t.problem with None -> 0 | Some _ -> 1
