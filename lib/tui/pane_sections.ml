(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type 'msg t = {
  label : string;
  facts : string list;
  ambient : bool;
  render : max_rows:int -> 'msg Mosaic.t list;
}

let section ~label ?(facts = []) ?(ambient = false) render =
  { label; facts; ambient; render }

let blank_row = box ~size:{ width = pct 100; height = px 1 } []

(* A section header: the [muted] label, then each fact in [faint] after a [faint]
   [Theme.separator]. Drawn with no wrap; short and bounded, so it clips at the
   pane column through the frame's hidden overflow rather than truncating here. *)
let header ~label ~facts =
  let fact_segs =
    List.concat_map
      (fun f -> [ seg Theme.faint Theme.separator; seg Theme.faint f ])
      facts
  in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~size:{ width = pct 100; height = px 1 }
    (seg Theme.muted label :: fact_segs)

(* Allocate the activity budget in list (priority) order. Each block costs one
   preceding blank (when anything is already emitted above it), its header, and
   its rows; a section that cannot fit its blank + header + one row is dropped
   whole with everything after it (lower priority, and [remaining] only shrinks),
   so no orphan header renders. An activity section that renders empty is skipped
   without consuming height (empty-state honesty) — a lower-priority section can
   still take its place. Returns the emitted blocks and the unused budget, which
   returns to the ambient section. *)
let alloc_activity ~emitted_above ~budget sections =
  let rec loop remaining emitted_any acc = function
    | [] -> (List.rev acc, remaining)
    | s :: rest ->
        let gap = if emitted_any then 1 else 0 in
        (* A section costs its blank (when it is not the first block), its header,
           and at least one row; below that it is dropped whole. *)
        let need = gap + 1 + 1 in
        if remaining < need then (List.rev acc, remaining)
        else
          let rows = s.render ~max_rows:(remaining - gap - 1) in
          if rows = [] then loop remaining emitted_any acc rest
          else
            let consumed = gap + 1 + List.length rows in
            loop (remaining - consumed) true ((s, gap, rows) :: acc) rest
  in
  loop budget emitted_above [] sections

let block ~gap section rows =
  (if gap > 0 then [ blank_row ] else [])
  @ (header ~label:section.label ~facts:section.facts :: rows)

let view ~width:_ ~max_rows sections =
  let total = max 1 max_rows in
  let ambient =
    match List.filter (fun s -> s.ambient) sections with
    | s :: _ -> Some s
    | [] -> None
  in
  let activity = List.filter (fun s -> not s.ambient) sections in
  (* Reserve the ambient floor (header + one row) so it always shows; the rest is
     the activity budget. The ambient block sits at the top, so the first activity
     block always has a blank above it. *)
  let ambient_floor = match ambient with Some _ -> 2 | None -> 0 in
  let activity_budget = max 0 (total - ambient_floor) in
  let activity_blocks, leftover =
    alloc_activity ~emitted_above:(ambient <> None) ~budget:activity_budget
      activity
  in
  (* Height the activity did not use returns to the ambient section, so it expands
     from the floor to its full glance when there is room. *)
  let ambient_out =
    match ambient with
    | None -> []
    | Some s ->
        let budget = ambient_floor + leftover in
        block ~gap:0 s (s.render ~max_rows:(max 1 (budget - 1)))
  in
  let activity_out =
    List.concat_map (fun (s, gap, rows) -> block ~gap s rows) activity_blocks
  in
  ambient_out @ activity_out
