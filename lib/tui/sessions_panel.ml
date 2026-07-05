(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type row = {
  id : Spice_session.Id.t;
  title : string;
  age : string;
  search_key : string;
}

type ready = { rows : row list; filter : string; selected : int }
type t = Loading | Failed of string | Ready of ready
type msg = Key of Panel.key

type event =
  | Stay
  | Close
  | Resume of Spice_session.Id.t
  | Promote of { filter : string; select : Spice_session.Id.t option }

let loading = Loading

(* Case-insensitive substring match over the filter key; the filter narrows the
   four rows the same way the old picker's query does, minus its scrollback. *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else loop (i + 1)
    in
    loop 0

let visible ready =
  if String.equal ready.filter "" then ready.rows
  else
    let needle = String.lowercase_ascii ready.filter in
    List.filter
      (fun row -> contains ~needle (String.lowercase_ascii row.search_key))
      ready.rows

(* The selection always names a visible row: clamp it into the filtered count
   whenever the filter or the rows change. *)
let clamp ready =
  match List.length (visible ready) with
  | 0 -> { ready with selected = 0 }
  | count -> { ready with selected = max 0 (min ready.selected (count - 1)) }

let loaded rows t =
  match t with
  | Loading | Failed _ -> Ready (clamp { rows; filter = ""; selected = 0 })
  | Ready ready -> Ready (clamp { ready with rows })

(* A transient store error renders its own line rather than the empty state,
   which would read as "no sessions" (the recorded honesty gap). Loaded rows are
   kept if some already arrived — a failed refresh does not blank them. *)
let failed message = function
  | Ready ready when ready.rows <> [] -> Ready ready
  | Loading | Failed _ | Ready _ -> Failed message

let key ev =
  match Panel.classify ev with
  | Panel.Action Panel.Other -> None
  | k -> Some (Key k)

let move delta ready =
  match List.length (visible ready) with
  | 0 -> ready
  | count ->
      { ready with selected = (((ready.selected + delta) mod count) + count) mod count }

let pick ready =
  match List.nth_opt (visible ready) ready.selected with
  | Some row -> (Ready ready, Resume row.id)
  | None -> (Ready ready, Stay)

(* A digit jump-picks the nth filtered row (1-indexed) while the filter is
   empty; out of range is a no-op, never a resume of the wrong session. *)
let jump ready d =
  if d < 1 then (Ready ready, Stay)
  else
    match List.nth_opt (visible ready) (d - 1) with
    | Some row -> (Ready ready, Resume row.id)
    | None -> (Ready ready, Stay)

(* Drop the last UTF-8 scalar of the filter, walking back over continuation
   bytes so a multibyte narrow deletes whole, not half a codepoint. *)
let drop_last s =
  let n = String.length s in
  if n = 0 then s
  else
    let rec back i =
      if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then back (i - 1) else i
    in
    String.sub s 0 (back (n - 1))

let narrow ready appended =
  (Ready (clamp { ready with filter = ready.filter ^ appended; selected = 0 }), Stay)

(* [tab] promotes to the browse screen, carrying the filter and the selected
   session so the screen opens exactly where the panel left off (03-ia
   §Sessions). *)
let promote ready =
  let select = Option.map (fun row -> row.id) (List.nth_opt (visible ready) ready.selected) in
  (Ready ready, Promote { filter = ready.filter; select })

let update (Key k) t =
  match t with
  | Loading | Failed _ -> (
      match k with Panel.Action Panel.Escape -> (t, Close) | _ -> (t, Stay))
  | Ready ready -> (
      match k with
      | Panel.Action Panel.Escape -> (Ready ready, Close)
      | Panel.Action Panel.Enter -> pick ready
      | Panel.Action Panel.Tab -> promote ready
      | Panel.Action Panel.Up -> (Ready (move (-1) ready), Stay)
      | Panel.Action Panel.Down -> (Ready (move 1 ready), Stay)
      | Panel.Action Panel.Backspace ->
          (Ready (clamp { ready with filter = drop_last ready.filter; selected = 0 }), Stay)
      | Panel.Printable s -> narrow ready s
      | Panel.Digit d ->
          if String.equal ready.filter "" then jump ready d
          else narrow ready (string_of_int d)
      | Panel.Action (Panel.Left | Panel.Right | Panel.Ctrl_d | Panel.Other) ->
          (Ready ready, Stay))

let default_style = Ansi.Style.default

(* The cursor cell is two columns ([❯ ] or two spaces); [❯] is three bytes, so
   its column width is stated rather than measured with [String.length]. *)
let cursor_cols = 2

let muted_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted s ]

let row_view ~width ~selected row =
  let inner = max 1 (width - 4) in
  let age = "  " ^ row.age in
  let age_w = String.length age in
  let title_w = max 1 (inner - cursor_cols - age_w) in
  let title = truncate_tail ~width:title_w row.title in
  let background = if selected then Some Theme.color_hover_bg else None in
  box ?background ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [
      cell cursor_cols
        (if selected then seg Theme.accent Theme.cursor else seg default_style "  ");
      cell title_w (seg default_style title);
      cell age_w (seg Theme.muted age);
    ]

let error_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.error (Theme.problem ^ s) ]

let content ~width t =
  match t with
  | Loading -> [ muted_line "⠋ loading sessions…" ]
  | Failed message -> [ error_line message ]
  | Ready ready -> (
      match ready.rows with
      | [] -> [ muted_line "No recent sessions in this workspace." ]
      | _ -> (
          match visible ready with
          | [] -> [ muted_line "No matching sessions." ]
          | rows ->
              List.mapi
                (fun i row -> row_view ~width ~selected:(i = ready.selected) row)
                rows))

(* The hint now advertises the working affordances honestly: resume attaches for
   real and tab promotes to the browse screen (doc/plans/tui-next-surfaces.md
   §Sequencing 5). *)
let view ~frame ~width t =
  let filter = match t with Loading | Failed _ -> "" | Ready ready -> ready.filter in
  Panel.view ~frame ~name:"sessions" ~filter ~width
    ~hint:[ "↵ resume"; "tab browse"; "type to filter"; "↑↓ select"; "esc close" ]
    ~content:(content ~width t)
