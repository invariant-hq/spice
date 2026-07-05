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
  | Up
  | Down
  | Left
  | Right
  | Backspace
  | Page_up
  | Page_down
  | Other

type key = Char of string | Action of action

let utf8_of_uchar u =
  let buffer = Buffer.create 4 in
  Buffer.add_utf_8_uchar buffer u;
  Buffer.contents buffer

let classify (ev : Matrix.Input.Key.event) =
  let open Matrix.Input in
  let m = ev.Key.modifier in
  let chord = m.Modifier.ctrl || m.Modifier.alt || m.Modifier.super in
  match ev.Key.key with
  (* [ctrl+p]/[ctrl+n] are the chorded aliases for [↑]/[↓] (03-ia §The filter
     law; 05/06 §Keybindings): a screen moves its selection by them too. *)
  | Key.Char u when m.Modifier.ctrl && Uchar.equal u (Uchar.of_char 'p') ->
      Action Up
  | Key.Char u when m.Modifier.ctrl && Uchar.equal u (Uchar.of_char 'n') ->
      Action Down
  | Key.Char u when not chord ->
      let code = Uchar.to_int u in
      if code >= 0x20 && code <> 0x7f then Char (utf8_of_uchar u)
      else Action Other
  | Key.Char _ -> Action Other
  | Key.Enter -> Action Enter
  | Key.Escape -> Action Escape
  | Key.Tab -> Action Tab
  | Key.Up -> Action Up
  | Key.Down -> Action Down
  | Key.Left -> Action Left
  | Key.Right -> Action Right
  | Key.Backspace | Key.Delete -> Action Backspace
  | Key.Page_up -> Action Page_up
  | Key.Page_down -> Action Page_down
  | _ -> Action Other

type filter = { query : string; matches : int }

(* A run of the rule glyph [─], drawn in the frame color; the count is a column
   count (the glyph is one column). *)
let dashes ~frame n =
  let s = String.concat "" (List.init (max 0 n) (fun _ -> "─")) in
  seg (Ansi.Style.make ~fg:frame ()) s

(* The top rule: [── ] then the name chip, dashes filling to the right-aligned
   fact, then a trailing [ ──]. The dash fill is computed in OCaml so the chip
   and fact land at deterministic columns without relying on flex text
   measurement (mosaic caches a node's width across renders — the flex-truncate
   quirk, doc/plans/tui-next.md §Rules). Names and facts are ASCII, so byte
   length is the column width. *)
let rule_row ~frame ~name ~fact ~width =
  let chip_cols = String.length name + 2 in
  let fact_cols = String.length fact in
  (* 3 lead ([── ]) + 1 gap + fill + 1 gap + fact + 3 trail ([ ──]). *)
  let fill = max 1 (width - 8 - chip_cols - fact_cols) in
  let rule_style = Ansi.Style.make ~fg:frame () in
  let pieces =
    [ seg rule_style "── "; Theme.chip ~color:frame name; dashes ~frame 1 ]
    @ [ dashes ~frame fill ]
    @ (if String.equal fact "" then [ dashes ~frame 2 ]
       else [ dashes ~frame 1; seg Theme.muted fact; seg rule_style " " ])
    @ [ seg rule_style "──" ]
  in
  box ~key:"screen.rule" ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~size:{ width = pct 100; height = px 1 }
    pieces

(* The bare filter line (03-ia §The filter law): an accent [/], the query in the
   default fg, then the match count faint — no rule, no cursor, no placeholder. *)
let filter_row filter =
  let count =
    if filter.matches = 1 then "  1 match"
    else if filter.matches = 0 then "  no matches"
    else Printf.sprintf "  %d matches" filter.matches
  in
  box ~key:"screen.filter" ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [
      seg Theme.atom "/";
      seg Ansi.Style.default filter.query;
      seg Theme.faint count;
    ]

(* The hint line sits where the footer was, same left padding, so a screen's
   affordances replace the footer row without shifting it. *)
let hint_row hints =
  let pieces =
    List.concat_map
      (fun (i, h) ->
        if i = 0 then [ seg Theme.faint h ]
        else [ seg Theme.muted Theme.separator; seg Theme.faint h ])
      (List.mapi (fun i h -> (i, h)) hints)
  in
  box ~key:"screen.hint" ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    pieces

let blank_row = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let view ~frame ~name ~fact ~filter ~hint ~width ~content =
  let filter_rows =
    match filter with Some f -> [ filter_row f; blank_row ] | None -> [ blank_row ]
  in
  box ~key:"screen" ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~size:{ width = pct 100; height = auto }
    ((rule_row ~frame ~name ~fact ~width :: filter_rows)
    @ content
    @ [ blank_row; hint_row hint ])
