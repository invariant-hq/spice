(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

(* The board's glyphs (02-tools.md §Todo block): the running and pending marks
   and the dotted strip rule. Theme.ml is co-owned and does not carry them yet,
   so they live here as local constants — the same interim convention strip.ml
   and tool_block.ml use for their own marks — until the vocabulary absorbs them.
   ◼/◻ are shared with tool_block.ml's settled block; when theme.ml gains them
   both modules reference the one source. *)
let running_glyph = "◼"
let pending_glyph = "◻"
let rule_glyph = "┈"

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

(* Pre-truncate in OCaml (the flex-truncate quirk, project memory): content is
   clipped to what remains after the indent and the [◼ ] mark so no row wraps. *)
let truncate ~width s =
  let s = first_line s in
  let budget = max 8 (width - 6) in
  if String.length s <= budget then s else String.sub s 0 (budget - 1) ^ "…"

(* Each board row is indented two columns — the transient-chrome margin above the
   composer that the strip's other tenants share (01-transcript.md §Base
   grammar). *)
let row style glyph content =
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 0 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [
      text ~style ~wrap:`None ~flex_shrink:0. (glyph ^ " ");
      text ~style ~wrap:`None content;
    ]

let text_row style value =
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 0 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ text ~style ~wrap:`None value ]

let done_fold_row count =
  text_row Theme.muted
    (Printf.sprintf "… %d done %s" count Theme.disclosure_closed)

let pending_overflow_row count =
  text_row Theme.faint
    (Printf.sprintf "… +%d more %s" count Theme.disclosure_closed)

(* The muted count header the mirror always leads with (02-tools.md §Todo block;
   §The task board carries the same "muted count header"): it holds the
   [N tasks · N done · N running] counts the settled block shows in its
   [⏺ Todo(…)] header, which the strip mirror has no [⏺] line to carry. Keyed by
   the pending mark so it reads as a todo board rather than the task board. *)
let count_header_row ~total ~done_count ~running_count =
  text_row Theme.muted
    (Printf.sprintf "%s %d tasks%s%d done%s%d running" pending_glyph total
       Theme.separator done_count Theme.separator running_count)

let take n xs =
  let rec loop n acc = function
    | x :: rest when n > 0 -> loop (n - 1) (x :: acc) rest
    | _ -> List.rev acc
  in
  loop n [] xs

let status_is status it =
  Spice_protocol.Todo.Status.equal (Spice_protocol.Todo.Item.status it) status

let project ~width todo =
  let items = Spice_protocol.Todo.items todo in
  let content it = truncate ~width (Spice_protocol.Todo.Item.content it) in
  let running =
    List.filter_map
      (fun it ->
        if status_is Spice_protocol.Todo.Status.In_progress it then
          Some (content it)
        else None)
      items
  in
  let pending =
    List.filter_map
      (fun it ->
        if status_is Spice_protocol.Todo.Status.Pending it then
          Some (content it)
        else None)
      items
  in
  let done_count =
    List.length
      (List.filter
         (fun it ->
           status_is Spice_protocol.Todo.Status.Completed it
           || status_is Spice_protocol.Todo.Status.Cancelled it)
         items)
  in
  (running, pending, done_count, List.length items)

let view ?(count_header = true) ~width ~max_rows todo =
  let running, pending, done_count, total = project ~width todo in
  let running_count = List.length running in
  (* The count header leads by default so the strip mirror carries the counts the
     block's [⏺ Todo(…)] header shows; item rows fill the remaining budget. The
     wide-terminal pane passes [~count_header:false] because its [tasks] section
     header already carries the counts ({!Pane_sections}), so repeating them here
     would duplicate them. Running rows render in full (02-tools.md §The task
     board, "running items full"); the pending window shrinks to fit, its
     remainder folded into a [… +N more ▸] row; done folds to [… N done ▸]. When
     nothing fits, the count header (when present) stands alone. *)
  let leading =
    if count_header then [ count_header_row ~total ~done_count ~running_count ]
    else []
  in
  let body_budget = max_rows - List.length leading in
  if body_budget <= 0 then leading
  else
    let running_rows = List.map (row Theme.running running_glyph) running in
    let done_fold =
      if done_count > 0 then [ done_fold_row done_count ] else []
    in
    let rec best k =
      if k < 0 then []
      else
        let shown = take k pending in
        let hidden = List.length pending - k in
        let rows =
          running_rows
          @ List.map (row Ansi.Style.default pending_glyph) shown
          @ (if hidden > 0 then [ pending_overflow_row hidden ] else [])
          @ done_fold
        in
        if List.length rows <= body_budget then rows else best (k - 1)
    in
    leading @ best (List.length pending)

let strip_rule ~width =
  let line = String.concat "" (List.init (max 0 width) (fun _ -> rule_glyph)) in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~size:{ width = pct 100; height = px 1 }
    [ text ~style:Theme.rule ~wrap:`None line ]
