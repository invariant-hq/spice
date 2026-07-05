(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type row =
  | Main
  | Thread of {
      glyph : string;
      style : Ansi.Style.t;
      name : string;
      task : string;
      facts : string list;
      depth : int;
      last : bool;
    }

(* The synthetic parent-anchor mark and the selected-row affordance. [◯] is not
   in the theme vocabulary yet and stays a local constant, the interim
   thread_view.ml and footer.ml take for their own glyphs. *)
let main_glyph = "◯"
let enter_hint = "enter to open"

(* Each row is a full-width single line indented two columns — the same
   transient-chrome margin the status strip uses (strip.ml), one grammar above
   and below the composer. *)
let line ?on_mouse children =
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0. ?on_mouse
    ~padding:(padding_lrtb 2 0 0 0)
    ~size:{ width = pct 100; height = px 1 }
    children

(* The selection cursor [❯ ] (accent) or its two-space blank, so selected and
   unselected rows stay column-aligned (00-overview.md §Interaction conventions). *)
let cursor selected = if selected then Theme.cursor else "  "

(* Byte width proxy for the fixed segments, so the task pre-truncates to the
   remaining columns rather than wrapping (the flex-truncate quirk). A multibyte
   glyph over-counts a touch and trims the task early — harmless, and the same
   posture strip.ml takes. *)
let width_of = String.length

(* The tree connector for a nested row: [├─ ] for a middle sibling, [└─ ] for
   the last, indented two columns per level below the first (decision 15). Root
   children (depth 0) carry none. Deeper vertical continuation lines are omitted
   — the tree is depth-capped and shallow. *)
let connector ~depth ~last =
  if depth <= 0 then ""
  else String.make ((depth - 1) * 2) ' ' ^ if last then "└─ " else "├─ "

let pad_right n s =
  let len = width_of s in
  if len >= n then s else s ^ String.make (n - len) ' '

let clip ~max s =
  if width_of s <= max then s
  else if max <= 1 then "…"
  else Thread_view.clip ~max s

let render_row ~width ~index ~selected ~hovered ~can_open ?on_mouse row =
  let cur = cursor selected in
  let hint = selected && can_open in
  (* Keyboard selection and mouse hover both light the row (accent); only the
     keyboard cursor moves the [❯] and shows the [enter to open] hint. *)
  let active = selected || hovered in
  let on_mouse = Option.map (fun f -> f index) on_mouse in
  match row with
  | Main ->
      let style = if active then Theme.accent else Theme.muted in
      line ?on_mouse
        (seg style (cur ^ main_glyph ^ " main")
        :: (if hint then [ seg Theme.faint (Theme.separator ^ enter_hint) ]
            else []))
  | Thread { glyph; style; name; task; facts; depth; last } ->
      let conn = connector ~depth ~last in
      let name_col = pad_right 10 name in
      let facts_str = String.concat Theme.separator facts in
      let hint_text = if hint then Theme.separator ^ enter_hint else "" in
      let body_style = if active then Theme.accent else Theme.muted in
      (* Budget the task to the columns the fixed segments leave: indent (2),
         cursor (2), connector, glyph and its space, the padded name, then the
         trailing facts and the selected hint (each behind a separator). *)
      let used =
        2 + 2 + width_of conn + width_of glyph + 1 + width_of name_col
        + (if facts = [] then 0 else width_of Theme.separator + width_of facts_str)
        + width_of hint_text
      in
      let task = clip ~max:(max 4 (width - used)) task in
      line ?on_mouse
        (List.concat
           [
             [ seg body_style cur ];
             (if conn = "" then [] else [ seg Theme.rule conn ]);
             [ seg style (glyph ^ " ") ];
             [ seg body_style (name_col ^ task) ];
             (if facts = [] then []
              else [ seg Theme.muted (Theme.separator ^ facts_str) ]);
             (if hint then [ seg Theme.faint hint_text ] else []);
           ])

let overflow_row ~width:_ n =
  line
    [
      seg Theme.faint ("… " ^ string_of_int n ^ " more (↓ to browse)");
    ]

let seam text = line [ seg Theme.muted text ]

(* The focused-browse window: keep the selection visible without the strip
   growing unbounded below the footer, [rows_avail] the rows it may take
   (model_panel.mli's pattern). *)
let window_limit rows_avail = max 1 (min 8 rows_avail)

let window ~limit ~selected ~count =
  if count <= limit then (0, count)
  else
    let start = selected - (limit / 2) in
    let start = max 0 (min start (count - limit)) in
    (start, limit)

let view ?(can_open = true) ?on_mouse ?(hovered = None) ~rows ~selected ~width
    ~rows_avail () =
  let is_hovered index = match hovered with Some h -> h = index | None -> false in
  match rows with
  | [] -> []
  | _ -> (
      let count = List.length rows in
      match selected with
      | None ->
          (* The unfocused glance: up to the first three rows, then a browse hint
             when the tree is longer — the whole block bounded by [rows_avail], so
             a caller that stacks the strip in a budgeted region (the side pane's
             agents section) gets exactly the height it granted, never an
             overflowing fourth row. When the budget forces a hint, one of its
             rows is the hint. *)
          let cap = max 1 rows_avail in
          let fits_without_hint = count <= 3 && count <= cap in
          let shown =
            if fits_without_hint then count else min (min 3 count) (cap - 1)
          in
          let visible = List.filteri (fun i _ -> i < shown) rows in
          let rendered =
            List.mapi
              (fun i r ->
                render_row ~width ~index:i ~selected:false
                  ~hovered:(is_hovered i) ~can_open ?on_mouse r)
              visible
          in
          rendered
          @ (if count > shown then [ overflow_row ~width (count - shown) ] else [])
      | Some sel ->
          (* The focused browse: the whole list windowed around the selection. *)
          let limit = window_limit rows_avail in
          let start, length = window ~limit ~selected:sel ~count in
          let visible =
            List.filteri (fun i _ -> i >= start && i < start + length) rows
          in
          let rendered =
            List.mapi
              (fun i r ->
                render_row ~width ~index:(start + i)
                  ~selected:(start + i = sel) ~hovered:(is_hovered (start + i))
                  ~can_open ?on_mouse r)
              visible
          in
          let above =
            if start > 0 then [ seam ("↑ " ^ string_of_int start ^ " more") ]
            else []
          in
          let below =
            if start + length < count then
              [ seam ("↓ " ^ string_of_int (count - start - length) ^ " more") ]
            else []
          in
          above @ rendered @ below)
