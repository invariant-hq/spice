(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The side panel's section framework: named, stacked sections with information
    hierarchy (doc/plans/tui-next-side-panel.md §Sections).

    The wide-terminal side panel is a stacked dashboard, not a
    one-tenant-at-a-time region: workspace state is ambient (always present)
    while activity — the todo board, the agent threads — stacks alongside it,
    each under its own named header. This module composes those content
    providers into one designed column; it owns the header treatment, the
    inter-section gap, and the height budget, and holds no tenant type or state
    of its own (the double-render law lives in the shell, {!Pane}).

    {b Header treatment.} Each section leads with a flush [muted] lowercase
    label and an optional live summary fact in [faint], joined by
    {!Theme.separator} ([workspace], [agents · 1 running],
    [tasks · 2 done · 1 running]). No filled chip (chips are whole-surface
    identity, {!Theme.chip}) and no rule — the header is flush and the content
    rows indent under it, so whitespace and indentation carry the hierarchy
    (00-overview.md §Design principles, content-first). One blank row separates
    adjacent sections; none precedes the first.

    {b Content.} A section's rows are its provider's own folding view
    ({!Todo_board.view}, {!Workspace_glance.view}, the threads rows) rendered to
    a granted [max_rows]. Providers indent their rows two columns under the
    header; this module never rewrites them.

    {b Empty-state honesty.} A section whose provider returns no rows does not
    render — no orphan header. The {e ambient} section (workspace) is the sole
    exception: it always renders, the pane's floor, because an empty pane reads
    as broken. *)

type 'msg t
(** One named section: a header (label + facts) and a folding row provider.
    Built by {!section}; composed by {!view}. *)

val section :
  label:string ->
  ?facts:string list ->
  ?ambient:bool ->
  (max_rows:int -> 'msg Mosaic.t list) ->
  'msg t
(** [section ~label ?facts ?ambient render] is a section headed [label] (drawn
    [muted], lowercase by convention) with [facts] (default [[]]) as a [faint]
    summary after the label, joined by {!Theme.separator}. [render ~max_rows] is
    the provider's view, returning at most [max_rows] rows already indented two
    columns under the header — it is the tenant's own height ladder, so a short
    grant folds the tenant's content, not this frame.

    [ambient] (default [false]) marks the always-present floor (workspace): an
    ambient section renders even when [render] would yield nothing and is
    protected under the height budget (it keeps a floor and expands into the
    leftover; see {!view}). At most one section is ambient. *)

val view : width:int -> max_rows:int -> 'msg t list -> 'msg Mosaic.t list
(** [view ~width ~max_rows sections] is the stacked column: each section's
    header then its rows, one blank row between adjacent sections, top to bottom
    in list order (the shell passes them in visual order). Total height is at
    most [max_rows]. Headers draw label and facts with no wrap and clip at the
    pane column ([width]) through {!Pane.frame}'s hidden overflow — they are
    short and bounded, so unlike the tenants' content rows they carry no
    in-OCaml truncation.

    {b The height budget.} The ambient section is reserved a floor (its header
    and one row) so it always shows; the remainder goes to the non-ambient
    sections in list order, each folding to its slice through its own
    [render ~max_rows]; any height the activity does not use returns to the
    ambient section so it expands to its full glance when there is room. A
    non-ambient section that cannot fit its header and one row is dropped whole
    (no orphan header). This frame never grows past [max_rows]; {!Pane.frame}'s
    hidden overflow is the final net. *)
