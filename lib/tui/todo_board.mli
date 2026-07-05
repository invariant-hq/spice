(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The live todo board: the status-strip mirror of the current turn's todo list
    (02-tools.md §Todo block, strip mirror; 01-transcript.md §The status strip).

    While a turn with a todo list is in flight the board renders above the
    composer as the glanceable "where are we" without scrolling back to the
    settled [⏺ Todo(…)] transcript block. It is a pure projection of one
    host-owned value the turn reducer already surfaces ({!Turn.todo_board} :
    {!Spice_protocol.Todo.t} option): each [todo_write] replaces the whole list,
    the accessor returns the latest, and it clears when the turn settles — so
    the board leaves the strip on settle and the settled document blocks are the
    record.

    This module is the single board renderer. {!view} is host-agnostic — the
    status strip mounts it above the composer (narrow terminals), and the
    wide-terminal activity pane (doc/plans/tui-next-side-panel.md) hosts the
    same rows inside its own column frame. Only the strip host adds
    {!strip_rule}; the pane draws its own [│] boundary. The two hosts are
    mutually exclusive per width (the pane absorbs the tenant at ≥110 cols), so
    the board never renders twice.

    Owner tags belong to the task board (02-tools.md §The task board), a
    different tenant; this board flattens all owners and carries no [@owner]
    tags. *)

val view :
  ?count_header:bool ->
  width:int ->
  max_rows:int ->
  Spice_protocol.Todo.t ->
  _ Mosaic.t list
(** [view ?count_header ~width ~max_rows todo] is the board's rows, at most
    [max_rows] tall, carrying no bounding rule (the host adds its own —
    {!strip_rule} for the strip, the [│] frame for the pane).

    The caller mounts this only when the board is present — visibility is
    decided once upstream from {!Turn.todo_board} being [Some] with items — so
    [todo] is non-empty and [max_rows] is at least 1.

    [count_header] (default [true]) leads with the muted count line
    [◻ N tasks · N done · N running] — the counts the settled block carries in
    its [⏺ Todo(…)] header, which the strip mirror has no [⏺] line to hold. The
    wide-terminal pane passes [false]: its [tasks] section header
    ({!Pane_sections}) already carries those counts, so the board renders its
    item rows alone and does not duplicate them. With [count_header:false] all
    [max_rows] go to the item rows. Below the header (when present) the item
    rows follow the block's grammar (02-tools.md §Todo block): a running item
    ([Spice_protocol.Todo.Status.In_progress]) is accent [◼], a pending item
    ([Pending]) is default [◻], and completed and cancelled items fold into one
    trailing [… N done ▸] digest so the running and pending work stays visible.
    Content is pre-truncated to [width] so no row wraps (the flex-truncate
    quirk).

    The height ladder fits the item rows into the budget below the header,
    folding more as it tightens: done always folds to the digest; running rows
    always render in full (02-tools.md §The task board, "running items full");
    pending rows fill the remaining budget with the overflow folded into a
    [… +N more ▸] row; and when nothing fits, the count header stands alone. The
    strip host derives [max_rows] from the terminal height and its reserve for
    the composer and footer, so a short terminal shows the header alone while a
    tall one shows the full board. *)

val strip_rule : width:int -> _ Mosaic.t
(** [strip_rule ~width] is the dotted [┈] rule (02-tools.md §The task board;
    01-transcript.md §The status strip) that bounds the whole status strip when
    the board is a strip tenant: a full-width [rule]-colored line the strip host
    mounts at the top of the strip region, above the board rows and the
    composer-affordance rows. It is chrome, lighter than a [─] seam. The
    wide-terminal pane draws its own [│] frame instead and does not use this. *)
