(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type group = Today | This_week | Older

type row = {
  id : Spice_session.Id.t;
  title : string;
  age : string;
  turns : int;
  preview : string option;
  lineage : string option;
  cwd : string;
  search_key : string;
  group : group;
}

(* The filter line is either closed (letters are the keymap) or open (printables
   narrow); esc closes it before it leaves the screen (03-ia §The filter law). *)
type filter = Closed | Open of string

(* The one in-place affordance the selected row may wear: the rename input over
   its title, or its own delete confirmation. Both live on the row, never in the
   composer (03-ia §Sessions, "in place"). *)
type editing = Browsing | Renaming of string | Confirming_delete

type ready = {
  rows : row list;
  filter : filter;
  editing : editing;
  selected : int;  (* index into the visible (filtered) rows *)
}

(* The filter text and selection a [tab] promotion carries from the panel, held
   until the rows load and it can be applied. *)
type pending = { query : string; select : Spice_session.Id.t option }

type t = Loading of pending | Load_error of string | Ready of ready
type msg = Key of Screen.key

type event =
  | Stay
  | Close
  | Resume of Spice_session.Id.t
  | Fork of Spice_session.Id.t
  | Rename of { id : Spice_session.Id.t; title : string }
  | Delete of Spice_session.Id.t

let loading = Loading { query = ""; select = None }
let promoted ~filter ~select = Loading { query = filter; select }
let failed message = Load_error message

(* Case-insensitive substring match, as the quick-switch panel filters. *)
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
  match ready.filter with
  | Closed | Open "" -> ready.rows
  | Open q ->
      let needle = String.lowercase_ascii q in
      List.filter
        (fun row -> contains ~needle (String.lowercase_ascii row.search_key))
        ready.rows

(* The selection always names a visible row: clamp it into the filtered count
   whenever the filter, the rows, or a delete change the count. *)
let clamp ready =
  match List.length (visible ready) with
  | 0 -> { ready with selected = 0 }
  | count -> { ready with selected = max 0 (min ready.selected (count - 1)) }

let select_id id ready =
  match
    List.find_index (fun row -> Spice_session.Id.equal row.id id) (visible ready)
  with
  | Some i -> { ready with selected = i }
  | None -> clamp ready

let loaded rows t =
  match t with
  | Loading pending ->
      let filter = if String.equal pending.query "" then Closed else Open pending.query in
      let ready = { rows; filter; editing = Browsing; selected = 0 } in
      Ready
        (match pending.select with
        | Some id -> select_id id ready
        | None -> clamp ready)
  | Load_error _ -> Ready (clamp { rows; filter = Closed; editing = Browsing; selected = 0 })
  | Ready ready -> Ready (clamp { ready with rows; editing = Browsing })

let key ev =
  match Screen.classify ev with Screen.Action Screen.Other -> None | k -> Some (Key k)

let selected_row ready = List.nth_opt (visible ready) ready.selected

let move delta ready =
  match List.length (visible ready) with
  | 0 -> ready
  | count -> { ready with selected = (((ready.selected + delta) mod count) + count) mod count }

(* Drop the last UTF-8 scalar, walking back over continuation bytes so a
   multibyte narrow or rename deletes whole, not half a codepoint. *)
let drop_last s =
  let n = String.length s in
  if n = 0 then s
  else
    let rec back i =
      if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then back (i - 1) else i
    in
    String.sub s 0 (back (n - 1))

let resume ready =
  match selected_row ready with
  | Some row -> (Ready ready, Resume row.id)
  | None -> (Ready ready, Stay)

let update_renaming ready text k =
  match k with
  | Screen.Action Screen.Escape -> (Ready { ready with editing = Browsing }, Stay)
  | Screen.Action Screen.Enter -> (
      let title = String.trim text in
      match (String.equal title "", selected_row ready) with
      | false, Some row ->
          (Ready { ready with editing = Browsing }, Rename { id = row.id; title })
      | _ -> (Ready { ready with editing = Browsing }, Stay))
  | Screen.Action Screen.Backspace ->
      (Ready { ready with editing = Renaming (drop_last text) }, Stay)
  | Screen.Char c -> (Ready { ready with editing = Renaming (text ^ c) }, Stay)
  | _ -> (Ready ready, Stay)

let update_confirming ready k =
  match k with
  | Screen.Char "d" -> (
      match selected_row ready with
      | Some row -> (Ready { ready with editing = Browsing }, Delete row.id)
      | None -> (Ready { ready with editing = Browsing }, Stay))
  (* Any other key — esc included — abandons the confirmation and restores the
     row (03-ia §Sessions). *)
  | _ -> (Ready { ready with editing = Browsing }, Stay)

let update_browsing_open ready q k =
  match k with
  | Screen.Action Screen.Escape -> (Ready { ready with filter = Closed }, Stay)
  | Screen.Action Screen.Enter -> resume ready
  | Screen.Action Screen.Up -> (Ready (move (-1) ready), Stay)
  | Screen.Action Screen.Down -> (Ready (move 1 ready), Stay)
  | Screen.Action Screen.Backspace ->
      (Ready (clamp { ready with filter = Open (drop_last q); selected = 0 }), Stay)
  | Screen.Char c -> (Ready (clamp { ready with filter = Open (q ^ c); selected = 0 }), Stay)
  | Screen.Action (Screen.Tab | Screen.Left | Screen.Right | Screen.Page_up | Screen.Page_down | Screen.Other)
    ->
      (Ready ready, Stay)

let update_browsing_closed ready k =
  match k with
  | Screen.Action Screen.Escape -> (Ready ready, Close)
  | Screen.Action Screen.Enter -> resume ready
  | Screen.Action Screen.Up -> (Ready (move (-1) ready), Stay)
  | Screen.Action Screen.Down -> (Ready (move 1 ready), Stay)
  | Screen.Char "/" -> (Ready { ready with filter = Open "" }, Stay)
  | Screen.Char "f" -> (
      match selected_row ready with
      | Some row -> (Ready ready, Fork row.id)
      | None -> (Ready ready, Stay))
  | Screen.Char "r" -> (
      match selected_row ready with
      | Some row -> (Ready { ready with editing = Renaming row.title }, Stay)
      | None -> (Ready ready, Stay))
  | Screen.Char "d" -> (
      match selected_row ready with
      | Some _ -> (Ready { ready with editing = Confirming_delete }, Stay)
      | None -> (Ready ready, Stay))
  | Screen.Char _ | Screen.Action (Screen.Tab | Screen.Left | Screen.Right | Screen.Page_up | Screen.Page_down | Screen.Backspace | Screen.Other)
    ->
      (Ready ready, Stay)

let update (Key k) t =
  match t with
  | Loading _ | Load_error _ -> (
      match k with Screen.Action Screen.Escape -> (t, Close) | _ -> (t, Stay))
  | Ready ready -> (
      match ready.editing with
      | Renaming text -> update_renaming ready text k
      | Confirming_delete -> update_confirming ready k
      | Browsing -> (
          match ready.filter with
          | Open q -> update_browsing_open ready q k
          | Closed -> update_browsing_closed ready k))

(* Rendering. *)

let default_style = Ansi.Style.default
let cursor_cols = 2

let plural n s = if n = 1 then s else s ^ "s"

let muted_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted s ]

let error_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.error (Theme.problem ^ s) ]

let group_header group =
  let label = match group with Today -> "today" | This_week -> "this week" | Older -> "older" in
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted label ]

let blank_row = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

(* One browse row: the cursor, the title (or its inline rename input), and the
   right-aligned [age · N turns] fact, laid out in fixed-width cells so the
   columns land deterministically despite mosaic's flex measurement caching
   (doc/plans/tui-next.md §Rules). A row confirming deletion renders its own
   warning line instead. *)
let row_view ~width ~selected ~editing row =
  let inner = max 1 (width - 4) in
  match (selected, editing) with
  | true, Confirming_delete ->
      box ~background:Theme.color_hover_bg ~flex_shrink:0.
        ~padding:(padding_lrtb 2 2 0 0)
        ~size:{ width = pct 100; height = px 1 }
        [ seg Theme.warning (Printf.sprintf "delete \"%s\"? press d again · esc cancel" row.title) ]
  | _ ->
      let detail = Printf.sprintf "  %s · %d %s" row.age row.turns (plural row.turns "turn") in
      let detail_w = String.length detail in
      let title_w = max 1 (inner - cursor_cols - detail_w) in
      let title_child =
        match (selected, editing) with
        | true, Renaming text -> seg Theme.accent (truncate_tail ~width:title_w (text ^ "▏"))
        | _ -> seg default_style (truncate_tail ~width:title_w row.title)
      in
      let background = if selected then Some Theme.color_hover_bg else None in
      box ?background ~flex_direction:Flex_direction.Row ~flex_shrink:0.
        ~padding:(padding_lrtb 2 2 0 0)
        ~size:{ width = pct 100; height = px 1 }
        [
          cell cursor_cols
            (if selected then seg Theme.accent Theme.cursor else seg default_style "  ");
          cell title_w title_child;
          cell detail_w (seg Theme.muted detail);
        ]

(* The selected row's expansion (03-ia §Sessions): a faint first-prompt echo,
   then a facts line — the home-relative cwd, plus the fork lineage when the
   session is a child. Both indent under the title. *)
let expansion_rows row =
  let indent = padding_lrtb 4 2 0 0 in
  let echo =
    match row.preview with
    | Some p when String.trim p <> "" ->
        [
          box ~flex_shrink:0. ~padding:indent ~size:{ width = pct 100; height = px 1 }
            [ seg Theme.faint (Theme.cursor ^ p) ];
        ]
    | _ -> []
  in
  let facts =
    let lineage = match row.lineage with Some l -> " · ↳ " ^ l | None -> "" in
    box ~flex_shrink:0. ~padding:indent ~size:{ width = pct 100; height = px 1 }
      [ seg Theme.muted (row.cwd ^ lineage) ]
  in
  echo @ [ facts ]

(* Window the visible rows around the selection, reserving room for the selected
   row's expansion, and summarize any overflow past the budget as a muted tail —
   the [… +N older] the spec calls for (03-ia §Sessions). *)
let window ~budget ~selected rows =
  let n = List.length rows in
  if n <= budget then (rows, 0)
  else
    let start = if selected < budget then 0 else selected - budget + 1 in
    let start = min start (n - budget) in
    let shown = List.filteri (fun i _ -> i >= start && i < start + budget) rows in
    (shown, n - start - budget)

let rows_view ~width ~rows ready visible =
  (* Content budget: the terminal height less the screen chrome (rule, filter or
     blank, the pre-hint blank, the hint) and the selected row's two expansion
     lines, floored so a short terminal still shows a few rows. *)
  let budget = max 3 (rows - 8) in
  let shown, older = window ~budget ~selected:ready.selected visible in
  (* Group headers track the group of the previous shown row, with a blank line
     above every group after the first (the overlay spacing, 05 §Section
     headers). The selection index is relative to [visible], so offset it into
     [shown]. *)
  let offset = List.length visible - List.length shown - older in
  let _, elements =
    List.fold_left
      (fun (i, acc) row ->
        let prev_group = if i = 0 then None else Some (List.nth visible (offset + i - 1)).group in
        let header =
          if Some row.group = prev_group then []
          else if i = 0 then [ group_header row.group ]
          else [ blank_row; group_header row.group ]
        in
        let is_selected = offset + i = ready.selected in
        let row_line = row_view ~width ~selected:is_selected ~editing:ready.editing row in
        let expansion =
          if is_selected && ready.editing = Browsing then expansion_rows row else []
        in
        (i + 1, acc @ header @ (row_line :: expansion)))
      (0, []) shown
  in
  let tail =
    if older > 0 then [ muted_line (Printf.sprintf "… +%d older" older) ] else []
  in
  elements @ tail

let content ~width ~rows t =
  match t with
  | Loading _ -> [ muted_line "⠋ loading sessions…" ]
  | Load_error message -> [ error_line message ]
  | Ready ready -> (
      match ready.rows with
      | [] -> [ muted_line "No sessions in this workspace." ]
      | _ -> (
          match visible ready with
          | [] -> [ muted_line "No matching sessions." ]
          | vis -> rows_view ~width ~rows ready vis))

let fact t =
  match t with
  | Loading _ | Load_error _ -> ""
  | Ready ready ->
      let n = List.length ready.rows in
      Printf.sprintf "%d %s" n (plural n "session")

let filter_line t =
  match t with
  | Loading _ | Load_error _ -> None
  | Ready ready -> (
      match ready.filter with
      | Closed -> None
      | Open q -> Some { Screen.query = q; matches = List.length (visible ready) })

let hint t =
  match t with
  | Loading _ | Load_error _ -> [ "esc back" ]
  | Ready ready -> (
      match ready.editing with
      | Renaming _ -> [ "↵ save"; "esc cancel" ]
      | Confirming_delete -> [ "d delete"; "esc cancel" ]
      | Browsing -> (
          match ready.filter with
          | Open _ -> [ "↵ resume"; "↑↓ select"; "esc clear filter" ]
          | Closed ->
              [ "↵ resume"; "f fork"; "r rename"; "d delete"; "/ filter"; "esc back" ]))

let view ~frame ~width ~rows t =
  Screen.view ~frame ~name:"sessions" ~fact:(fact t) ~filter:(filter_line t)
    ~hint:(hint t) ~width ~content:(content ~width ~rows t)
