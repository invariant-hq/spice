(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The review screen's design tokens: colors, text styles, glyphs, layout
    helpers, and diff themes.

    This is the review sub-library's local realization of the spice design
    language (doc/ui-design/00-overview.md, 11-review.md). It duplicates the
    language rather than sharing {!Spice_tui.Theme}, which is a private module
    of the [spice_tui] library and so unreachable from this separate library —
    the same reason the old [lib/tui/review] carries its own [style.ml]
    (doc/plans/tui-next-review.md §divergence 5). The constant values are kept
    in sync with tui-next's [Theme] by convention; deliberate changes travel
    through the docs to both. *)

(** {1:colors Color roles} *)

val color_muted : Mosaic.Ansi.Color.t
(** [color_muted] is secondary text. *)

val color_faint : Mosaic.Ansi.Color.t
(** [color_faint] is tertiary text. *)

val color_rule : Mosaic.Ansi.Color.t
(** [color_rule] is horizontal rules. *)

val color_accent : Mosaic.Ansi.Color.t
(** [color_accent] is paprika, the one brand hue: cursors, selection, active
    input. Its value deliberately duplicates [Spice_tui.Theme.color_accent]
    ([rgb(214,96,60)]) — a hand-kept sync, not an independent choice, since
    [Theme] is a private module of [spice_tui] and unreachable here. A change to
    the brand hue must touch both this constant and [Theme.color_accent]; that
    drift risk is the price of the separate library. *)

val color_success : Mosaic.Ansi.Color.t
(** [color_success] is the positive-outcome color. *)

val color_warning : Mosaic.Ansi.Color.t
(** [color_warning] is the caution-outcome color. *)

val color_error : Mosaic.Ansi.Color.t
(** [color_error] is the failure-outcome color. *)

val color_overlay : Mosaic.Ansi.Color.t
(** [color_overlay] is the opaque backdrop of the compose dialog — the review
    screen's one sanctioned filled surface (11-review.md §CR compose). *)

(** {1:styles Text styles} *)

val muted : Mosaic.Ansi.Style.t
val faint : Mosaic.Ansi.Style.t
val rule : Mosaic.Ansi.Style.t
val bold : Mosaic.Ansi.Style.t
val accent : Mosaic.Ansi.Style.t
val success : Mosaic.Ansi.Style.t
val warning : Mosaic.Ansi.Style.t
val error : Mosaic.Ansi.Style.t

(** {1:glyphs Glyph vocabulary} *)

val cursor : string
(** [cursor] is the selected-row marker (["❯ "]). *)

val cursor_blank : string
(** [cursor_blank] keeps unselected rows aligned with {!cursor} rows (["  "]).
*)

val problem : string
(** [problem] marks a problem line (["! "]). *)

val separator : string
(** [separator] joins inline facts ([" · "]). *)

val v_separator : string
(** [v_separator] is the full-height rule between the two panes (["│"]) — the
    sanctioned glyph of the two-column waiver, this screen only. *)

val tree_group : string
(** [tree_group] heads a directory group row (["▾"]). *)

val todo_pending : string
(** [todo_pending] is the unreviewed mark (["[ ]"]). *)

val todo_done : string
(** [todo_done] is the reviewed mark (["[✓]"]). *)

(** {1:layout Layout helpers} *)

val default_rule_width : int
(** [default_rule_width] is the fallback panel width when none is supplied. *)

val panel_rule : ?width:int -> unit -> _ Mosaic.t
(** [panel_rule ?width ()] is the [─] top rule spanning [width] in {!rule}. *)

val window : limit:int -> selected:int -> count:int -> int * int
(** [window ~limit ~selected ~count] is the [(start, length)] slice of a
    [count]-row list that keeps [selected] visible within [limit] rows. *)

val scrolled_above : int -> _ Mosaic.t
(** [scrolled_above n] is the muted [↑ N more] overflow marker. *)

val scrolled_below : int -> _ Mosaic.t
(** [scrolled_below n] is the muted [↓ N more] overflow marker. *)

val pad_right : int -> string -> string
(** [pad_right width value] right-pads [value] with spaces to [width]. *)

(** {1:diff Diff themes} *)

val diff_theme : Mosaic.Diff.theme
(** [diff_theme] is the review diff rendering, matching the transcript's diff
    colors. *)

val diff_quieted : Mosaic.Diff.theme
(** [diff_quieted] is the reviewed-scope variant: add/del backgrounds dropped
    and signs muted, so settled content stops shouting. *)

val diff_dimmed : Mosaic.Diff.theme
(** [diff_dimmed] is the compose-dialog variant: the same picture at half
    brightness, so the diff reads as dimmed rather than losing its colors. *)
