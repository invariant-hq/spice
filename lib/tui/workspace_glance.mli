(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The side panel's idle tenant: the live workspace glance
    (doc/plans/tui-next-side-panel.md; 12-home.md §Workspace block).

    While no turn streams, the wide-terminal side panel shows the {!Home.Brief.t}
    workspace facts — the newest session, dune health, worktree delta, CR counts —
    that the home stage shows and the drop scrolls away. This is a pure narrow
    view; the shell selects it as the pane's [~right] when idle and hosts it
    through {!Pane.frame}.

    Display-only: the pane takes no keys, so the glance carries no slash atom (an
    un-actionable [/review] would break hint honesty, 00-overview.md §Honest
    state) — unlike the home block's worktree line. The per-fact wording is the
    pane's own terser vocabulary over the same public host facts, not the home
    block's (which has an 11-column label column and more room); the two are
    independent views of {!Home.Brief.t}. *)

val view : width:int -> max_rows:int -> Home.Brief.t -> 'msg Mosaic.t list
(** [view ~width ~max_rows brief] is the glance's rows, at most [max_rows] tall.
    Rows render in display order — dune (always), worktree, CRs, session — and the
    [option] facts render only when present. Under a tight [max_rows] the facts
    shed bottom-up (session, then CRs, then worktree; the dune line survives
    longest — spice's core loop, 12-home.md §States). Muted, label-less, each row
    indented two columns under the pane's [workspace] section header
    ({!Pane_sections}); the worktree delta keeps the success/error [+A −D] pair and
    a failing dune build reads [warning]. The session title pre-truncates to leave
    [width] room for its
    age (the flex-truncate quirk); the fixed-form rows are terse and clip at the
    pane column when narrower.

    Invariant: every match over a host fact type — the [Health.t] build state
    especially — is {b exhaustive}, no [_] wildcard. This is the drift guard for
    rendering the same host facts in two vocabularies (here and the home block): a
    new [Health.t] state must break this build, not render wrong silently. *)
