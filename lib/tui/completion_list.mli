(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The shared completion-list anatomy: a selection-centered window with one
    cursor treatment, drawn above the composer's top rule.

    The slash palette, the [@] mention list, and the [ctrl+r] history search all
    render through this module so the three read as one control
    (03-ia-screens-overlays.md §Completions). This module owns only the shared
    frame — the cursor column, the 5-row window centered on the selection with
    [↑ N more] / [↓ N more] seam rows, and the empty/loading/error note rows.
    Each row's content (its columns and per-selection styling) is the caller's:
    a row is a list of pre-styled {!segment}s that the caller lays out and,
    crucially, pre-truncates. Mosaic's flex truncation measures at a stale
    width, so callers size their strings in OCaml and this module never relies
    on [~truncate].

    Selection and window math are exposed ({!window}) so the shell's key
    handling and the view agree on which rows are visible. *)

(** {1:rows Rows} *)

type segment
(** The type for a styled run of text within a row. *)

val segment : ?style:Mosaic.Ansi.Style.t -> string -> segment
(** [segment ?style text] is [text] drawn in [style]. [style] defaults to the
    terminal's default foreground. [text] is drawn verbatim with no wrapping or
    truncation — pre-truncate it to the available width. *)

type row = segment list
(** The type for one row's content, left to right. The content excludes the
    cursor column: {!view} prepends [❯ ] to the selected row and two spaces to
    the rest, so a row's first segment aligns under both (03-composer.md §Slash
    palette). *)

(** {1:window Window math} *)

type window = {
  start : int;  (** Index of the item shown in the first slot. *)
  length : int;  (** Number of rendered slots, at most {!max_visible}. *)
  hidden_above : int;
      (** Items above the first {e visible} item; [0] means no top seam,
          otherwise the top slot is a [↑ hidden_above more] seam. *)
  hidden_below : int;
      (** Items below the last {e visible} item; [0] means no bottom seam,
          otherwise the bottom slot is a [↓ hidden_below more] seam. *)
}
(** The type for the visible slice of a completion list. *)

val max_visible : int
(** [max_visible] is [5] — the window height in rows, seams included. *)

val window : total:int -> selected:int -> window
(** [window ~total ~selected] is the slice of a [total]-item list to render with
    row [selected] highlighted. The window holds at most {!max_visible} slots,
    keeps [selected] visible, and centers it when the list overflows; the seam
    slots ({!hidden_above}, {!hidden_below}) count the items they stand in for.
    [selected] is clamped to [[0; total-1]]; [total = 0] yields an empty window.
*)

(** {1:views Views} *)

val view : selected:int -> row list -> _ Mosaic.t
(** [view ~selected rows] renders the {!window} of [rows] with row [selected]
    highlighted: each visible slot is its row content behind a [❯ ] (accent) or
    two-space cursor, with [↑ N more] / [↓ N more] muted seam rows at
    overflowing edges. [selected] is clamped to [rows]. An empty [rows] renders
    nothing — use {!note} or {!error} for the empty, loading, and failure
    states. *)

val note : string -> _ Mosaic.t
(** [note text] is a single muted line at the rows' indent, for the empty and
    loading states ([no matching commands], [loading files…]). The caller owns
    the copy so it stays honest to the surface. *)

val error : string -> _ Mosaic.t
(** [error text] is [text] behind a [! ] marker in the error color, for a
    failure to produce the list (03-ia-screens-overlays.md §Completions). *)
