(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The subagent-threads switcher strip, below the footer
    (03-ia-screens-overlays.md §Agent threads; doc/plans/tui-next-threads.md §0,
    §2.6, §4.2).

    This is the {e only} switcher surface — there is no threads panel (the
    design cut it, §2.7). It renders the same rows at two heights, chosen by
    [selected]:

    - the {b unfocused glance} ([selected = None]): the composer holds the
      keyboard and the strip is an ambient readout — at most three rows ([Main]
      first, then the shell's running-then-unread order) plus a
      [… N more (↓ to browse)] overflow row when the tree exceeds three, the
      whole block bounded by [rows_avail] so a caller stacking it in a budgeted
      region never overflows its grant;
    - the {b focused browse} ([selected = Some i]): [↓] stepped in, so the strip
      expands in place and windows over the whole ordered list around row [i]
      with [↑ N]/[↓ N more] seam rows, the window height derived from
      [rows_avail] like {!Model_panel}. The selected row wears the [❯] cursor and
      an [enter to open] hint.

    It is a pure view: the shell owns the row order, the selection, and all key
    routing (empty-draft [↓]/[↑]/[↵]/[esc], the composer non-modality) — this
    module never decides visibility or focus, matching where the old TUI keeps
    [strip_focus]/[strip_key]. Distinct from {!Strip}, which is the status strip
    {e above} the composer (verbose lens, queued prompts). *)

open Mosaic

(** One switcher row. [Main] is the parent conversation's anchor row, drawn
    [◯ main] and always first; [Thread] is a child run, its facts and glyph
    pre-formatted by {!Thread_view} so this module stays render-only. *)
type row =
  | Main
  | Thread of {
      glyph : string;  (** The status mark ({!Thread_view.glyph}). *)
      style : Ansi.Style.t;  (** The status color ({!Thread_view.style}). *)
      name : string;  (** The role label (["Explore"], …). *)
      task : string;  (** The spawn task, single line; pre-truncated here. *)
      facts : string list;
          (** Trailing facts already formatted — elapsed, [↓ tokens], an
              attention fact — joined with {!Theme.separator}. *)
      depth : int;  (** Tree depth; [0] for a root child, deeper for nesting. *)
      last : bool;
          (** Whether this row is the last of its sibling group, choosing the
              [└─] versus [├─] connector at [depth > 0]. *)
    }

val view :
  ?can_open:bool ->
  ?on_mouse:(int -> Event.Mouse.t -> 'msg option) ->
  ?hovered:int option ->
  rows:row list ->
  selected:int option ->
  width:int ->
  rows_avail:int ->
  unit ->
  'msg t list
(** [view ?can_open ?on_mouse ?hovered ~rows ~selected ~width ~rows_avail ()] is
    the strip's rows, or the empty list when [rows] is empty (so the caller
    mounts it unconditionally, like {!Strip.view}). [rows] is in display order
    with [Main] first. [can_open] (default [true]) gates the selected row's
    [enter to open] hint: pass [false] while the selected row is not openable so
    the strip is honestly browse-only (the honest-hint rule).

    [on_mouse i ev] is attached to row [i] (the absolute index in [rows], the
    same index [selected]/[hovered] use), so the shell maps a click to that row's
    run; it returns [None] for events it ignores (a wheel then bubbles to the
    transcript, the wheel-always-scrolls law). [hovered] is the absolute index the
    pointer is over, lighting that row like a selection but without moving the
    [❯] cursor. Both default to no mouse behaviour.

    [selected = None] is the glance: up to the first three rows, then a
    [… N more (↓ to browse)] overflow row when [rows] is longer — the block
    height bounded by [rows_avail], so the hint replaces content rows rather than
    overflowing when the budget is tight. [selected = Some i] is the browse: the
    whole list windowed around row [i] — height bounded by [rows_avail] — with
    [↑ N more]/[↓ N more] seams past the window edges, the [i]th row carrying the
    [❯] cursor and an [enter to open] hint.

    [width] is the terminal column count; each row spans it and its task
    pre-truncates in OCaml so no row wraps (the flex-truncate quirk). *)
