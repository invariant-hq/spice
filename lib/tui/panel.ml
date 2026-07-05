(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type action =
  | Enter
  | Escape
  | Tab
  | Left
  | Right
  | Up
  | Down
  | Backspace
  | Ctrl_d
  | Other

type key = Printable of string | Digit of int | Action of action

let utf8_of_uchar u =
  let buffer = Buffer.create 4 in
  Buffer.add_utf_8_uchar buffer u;
  Buffer.contents buffer

let classify (ev : Matrix.Input.Key.event) =
  let open Matrix.Input in
  let m = ev.Key.modifier in
  let chord = m.Modifier.ctrl || m.Modifier.alt || m.Modifier.super in
  match ev.Key.key with
  | Key.Char u when m.Modifier.ctrl && Uchar.equal u (Uchar.of_char 'd') ->
      Action Ctrl_d
  (* [ctrl+p]/[ctrl+n] are the chorded aliases for [↑]/[↓] every list moves by
     (05/06/07 §Keybindings); they resolve to the same actions so no surface
     re-derives them. *)
  | Key.Char u when m.Modifier.ctrl && Uchar.equal u (Uchar.of_char 'p') ->
      Action Up
  | Key.Char u when m.Modifier.ctrl && Uchar.equal u (Uchar.of_char 'n') ->
      Action Down
  | Key.Char u when not chord ->
      let code = Uchar.to_int u in
      if code >= 0x30 && code <= 0x39 then Digit (code - 0x30)
      else if code >= 0x20 && code <> 0x7f then Printable (utf8_of_uchar u)
      else Action Other
  | Key.Char _ -> Action Other
  | Key.Enter -> Action Enter
  | Key.Escape -> Action Escape
  | Key.Tab -> Action Tab
  | Key.Left -> Action Left
  | Key.Right -> Action Right
  | Key.Up -> Action Up
  | Key.Down -> Action Down
  | Key.Backspace | Key.Delete -> Action Backspace
  (* A panel's list is short (05 caps it at 8 rows), so a page key degrades to a
     single-row step rather than dying — there is no wide pane to page. *)
  | Key.Page_up -> Action Up
  | Key.Page_down -> Action Down
  | _ -> Action Other

(* The boundary spans the terminal: the glyph repeated to [width], drawn in the
   frame color so it reads as the panel's own edge, not a rule. *)
let boundary ~frame ~width =
  let s = String.concat "" (List.init (max 0 width) (fun _ -> Theme.panel_boundary)) in
  box ~key:"panel.boundary" ~flex_shrink:0.
    ~size:{ width = pct 100; height = px 1 }
    [ text ~style:(Ansi.Style.make ~fg:frame ()) ~wrap:`None s ]

(* The name chip, with the live filter echoed faint to its right — a panel has
   no dedicated filter line (03-ia §The filter law), so the typed text rides
   beside the chip as the one narrowing readout. *)
let chip_row ~frame ~name ~filter =
  let echo =
    if String.equal filter "" then []
    else [ seg Theme.faint ("  " ^ filter) ]
  in
  box ~key:"panel.chip" ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    (Theme.chip ~color:frame name :: echo)

(* The hint line sits exactly where the footer was — same left padding — so the
   panel's affordances replace the footer row without shifting it. *)
let hint_row hints =
  let pieces =
    List.concat_map
      (fun (i, h) ->
        if i = 0 then [ seg Theme.faint h ]
        else [ seg Theme.muted Theme.separator; seg Theme.faint h ])
      (List.mapi (fun i h -> (i, h)) hints)
  in
  box ~key:"panel.hint" ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    pieces

let blank_row = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let view ~frame ~name ~filter ~hint ~width ~content =
  box ~key:"panel" ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~size:{ width = pct 100; height = auto }
    ([ boundary ~frame ~width; chip_row ~frame ~name ~filter; blank_row ]
    @ content
    @ [ blank_row; hint_row hint ])
