(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The wide-terminal side panel — the context & activity column
    (doc/plans/tui-next-side-panel.md; 01-transcript.md §Wide terminals).

    At [>= min_cols] columns, in the chat phase, a fixed column opens to the
    right of a [│] rule. It carries the turn's activity while a turn streams (the
    live todo board, then the tool feed and threads as their seams land) and a
    quiet ambient glance while idle. The composer and footer span the full width
    below it.

    {b Two laws.}

    - {b The transcript is fluid} (Thibaut's ruling, 2026-07-08): it renders at
      the width it is given — full terminal width with the pane closed,
      {!transcript_width} with it open. There is no 80-column cap; the earlier cap
      design is dead. The pane is sized transcript-first: an open pane never takes
      the transcript below 80 columns (see {!width}).
    - {b Pane presence is a pure function of width, never of turn state.} At
      [>= min_cols] (with the {!keep_open_cols} hysteresis, {!presence}) the region
      exists; the turn varies its {e content}, not the region. A turn-scoped pane
      over a fluid transcript would rewrap the whole document at every turn
      boundary — so presence tracks width, and reflow happens only on a real
      terminal resize across the threshold.

    {b The tenant seam is data.} This module has no tenant type and holds no
    state: it is a pure two-column host. The shell picks the region's content
    once — the highest-priority live tenant while streaming, the idle ambient
    glance otherwise — renders it to rows through that content's own module (e.g.
    {!Todo_board.view}), and hands the rows here as [~right]. So each content
    source lives in exactly one module and the pane re-implements none of them,
    and the shell — the one source of visibility truth — routes a tenant's rows
    to exactly one region (the strip {e or} the pane, never both: the
    double-render law).

    {b Display-only.} The pane never captures keys, focus, or the wheel. The
    wheel always scrolls the transcript (01-transcript.md); pane overflow degrades
    to the tenant's own digest rather than scrolling — the pane is never a
    scrollport. *)

val min_cols : int
(** [min_cols] is 110: the pane region opens at [cols >= min_cols]
    (01-transcript.md §Wide terminals). *)

val keep_open_cols : int
(** [keep_open_cols] is 109: once present, the region persists down to this width,
    a hysteresis dead band so dragging a resize across {!min_cols} does not thrash
    the layout. It is the lowest width that still holds the 80-column transcript
    floor beside the 28-column pane minimum and the 1-column rule (80 + 28 + 1),
    so an open pane never dips the transcript below its floor. *)

val presence : cols:int -> was:bool -> bool
(** [presence ~cols ~was] is whether the pane region shows, [was] the previous
    decision: it opens at [cols >= min_cols] and, once open, stays open down to
    [cols >= keep_open_cols] (the {!min_cols}/{!keep_open_cols} hysteresis law).
    The shell holds only the previous boolean and re-derives nothing — the
    thresholds live here, not in the shell. *)

val width : cols:int -> int
(** [width ~cols] is the pane column's width to the right of the [│] rule:
    [max 28 (min 40 (cols - 81))]. Invariants (transcript-first, per Thibaut's
    ruling):

    - an open pane never takes the transcript below 80 columns — at the
      {!min_cols} threshold the split is pane 28–29 + rule 1 + transcript 80–81;
    - the pane grows with the terminal only up to a 40-column cap, and {e all}
      width beyond that flows to the transcript ("the transcript takes the space
      it has").

    Not a fraction of the terminal — a fraction would throttle the transcript's
    growth. Tunable. *)

val content_width : cols:int -> int
(** [content_width ~cols] is {!width} less the pane's left padding: the width a
    tenant renders its rows at (e.g. {!Todo_board.view}'s [~width]). *)

val content_rows : rows:int -> int
(** [content_rows ~rows] is the row budget the pane grants a tenant at terminal
    height [rows] — approximately the transcript-region height, so a tenant folds
    its own content to fit (the shell passes it as {!Todo_board.view}'s
    [~max_rows]). It is an approximation; {!frame} clips with a hidden
    overflow so an over-budget tenant never grows the row and pushes the composer
    (the layout-stability law). Always [>= 1]. *)

val transcript_width : cols:int -> open_:bool -> int
(** [transcript_width ~cols ~open_] is the width the shell renders the fluid
    transcript at: [cols] when the pane is absent, [cols - width ~cols - 1] (the
    rule) when present — [>= 80] at [cols >= min_cols], and growing past 80 once
    {!width} caps at 40. The document wraps to this real column. Always [>= 1]. *)

val frame :
  cols:int ->
  open_:bool ->
  left:'msg Mosaic.t ->
  right:'msg Mosaic.t list ->
  'msg Mosaic.t
(** [frame ~cols ~open_ ~left ~right] is the transcript region:

    - [not open_] — [left] alone, full width (a narrow terminal).
    - [open_] — two columns: [left] (the transcript, already rendered at
      {!transcript_width}) flex-growing, then the [│] rule and [right] (the live
      tenant's or the idle glance's pre-rendered rows) in the fixed pane column
      ([width ~cols] wide, plus the rule).

    Presence is [~open_] {e alone} — the width-driven decision. [~right] may be
    empty and the region still shows (an over-degraded glance); it never collapses
    the pane on turn state. The [│] rule is a left border in {!Theme.color_rule}
    on the pane column, stretched to the region height by the row's default item
    alignment, so it spans the full height however short the rows are. The pane
    column clips its overflow, so it can never push the composer.

    This is the single owner of the two-column geometry and the [│] rule; no
    other module draws them. *)
