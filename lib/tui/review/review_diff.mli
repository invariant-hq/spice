(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The review diff pane: the selected file's unified diff with a scope line
    above it, inside a scroll box (11-review.md §Diff pane).

    Each hunk is its own node so mixed files quiet hunk by hunk; the cursor's
    hunk/line carries the gutter cursor (accent when the diff pane holds focus,
    muted otherwise) and a subtle line-highlight wash. A reviewed hunk quiets
    (backgrounds dropped, text muted); a CR anchored outside any hunk gets a
    synthesized context-only view. Auto-scroll keeps the cursor line on screen
    via a one-shot {!Mosaic.scroll_box} reveal keyed on the cursor. Pure: it
    reads the review and produces rows; the component owns the cursor. *)

val view :
  ?width:int ->
  ?height:int ->
  ?focused:bool ->
  ?dimmed:bool ->
  ?compose_anchor:string * int ->
  ?on_line_click:(Spice_review.Scope.t -> 'a) ->
  Spice_review.t ->
  full_context:bool ->
  'a Mosaic.t list
(** [view ?width ?height ?focused ?dimmed ?compose_anchor ?on_line_click review
     ~full_context] is the scope line plus the scroll box for the file the
    cursor selects. Hunks render at the review's context; [full_context]
    recomputes the whole file. [compose_anchor] is a [(path, line)] the compose
    dialog will land on, given a stronger [warning] wash; [on_line_click]
    reports the exact source line a click hits as a {!Spice_review.Scope.Line}.
*)
