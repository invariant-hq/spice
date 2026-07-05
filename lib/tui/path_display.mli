(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Path formatting for the chrome: home-abbreviation and column-budget
    ellipsis.

    These are the presentation rules the banner and footer share
    (04-header-footer.md, 12-home.md). Facts are the host's; this ellipsis and
    the [~/…] abbreviation are the TUI's. [lib/path] ([Spice_path]) models paths
    but carries no display rules, and [lib/tui]'s equivalent is private to the
    old TUI, so the rules live here.

    Widths are column budgets. Paths are treated as ASCII — one byte is one
    column and the ellipsis ["…"] counts as one column — which is exact for the
    paths we render and close enough for a rare multibyte component. *)

val home_relative : Spice_path.Abs.t -> string
(** [home_relative path] is [path] with the process [HOME] prefix collapsed to
    ["~"] (["~/rest"] under it, the home directory itself as ["~"]), and [path]
    unchanged when it lies outside [HOME] or [HOME] is unset. *)

val left_truncate : width:int -> string -> string
(** [left_truncate ~width s] keeps the last [width] columns of [s], dropping the
    head behind a leading ["…"] and aligning the cut to a ["/"] when one falls
    inside the kept window, so the leaf and its parent stay legible
    (["…/invariant/spice"]). It is [s] unchanged when [s] already fits or
    [width] is too small to keep more than the ellipsis. This is the footer's
    cwd rule (04-header-footer.md §2, gap 6): the tail is the informative part.
*)

val middle_truncate : width:int -> string -> string
(** [middle_truncate ~width s] keeps the first segment of [s] (["~"], ["/root"],
    or the whole string when it has no ["/"]) and as much of the tail as fits,
    joined by ["…"], dropping from the middle. It is [s] unchanged when [s]
    already fits. This is the compact banner record's cwd rule
    (04-header-footer.md §1): the root and the leaf both survive. *)
