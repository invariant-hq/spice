(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The home stage: the centered brand, the inset composer, the centered
    workspace block, and the lockup motion (12-home.md).

    The stage is what spice shows before a session begins: the lockup and facts
    over an inset composer at the visual center, with the workspace block (dune,
    worktree, CRs, session) centered as a unit beneath it. It fills the height
    above the footer (owned by the shell); the footer never moves, and on the
    first submit the shell drops the composer to the bottom (12-home.md §The
    drop). This module composes the surfaces and owns the lockup's playback
    state; {!Theme} owns the frame data, {!Banner} the brand and the record. *)

(** The live workspace facts the stage reflects (12-home.md §Liveness).

    A pure data record: the facts the runtime assembles from the host's watchers
    (dune health, the worktree glance, CR counts, the newest session) on a short
    cadence while the home stage is showing, and stops refreshing at the drop.
    It is the runtime↔shell wire type for the workspace facts, rendered by the
    home stage and, after the drop, by the wide-terminal side panel's idle
    glance (doc/plans/tui-next-side-panel.md). The shell holds [t option]:
    [None] until the first load lands (the stage shows a loading spinner),
    [Some] thereafter — a transiently failing refresh keeps the last known facts
    rather than reverting to empties.

    Ages are formatted here (formatting is the TUI's); the underlying facts are
    the host's. *)
module Brief : sig
  type session = {
    id : Spice_session.Id.t;
        (** The session an empty-draft [↵] resumes directly (12-home.md
            §Keybindings); not rendered — the recognition surface is the title.
        *)
    title : string;
        (** The session's display title — never a raw id: an untitled session
            falls back to its first-prompt preview, then to ["untitled"]
            (12-home.md §Workspace block). *)
    age : string;  (** The relative age of its last update (e.g. ["2h ago"]). *)
  }
  (** The type for the newest resumable session, rendered as the [session] fact.
  *)

  type t = {
    dune : Spice_ocaml_dune.Rpc.Instance.Health.t;
        (** Dune connectivity and build verdict. *)
    worktree : Spice_diff.stats option;
        (** Worktree change statistics, [Some] only when the worktree differs
            from HEAD. *)
    crs : Spice_cr.Occurrence.counts option;
        (** Open CR counts, [Some] only when at least one CR is open. *)
    session : session option;
        (** The newest resumable session in the cwd, [Some] only when one
            exists, for the [session] fact line. *)
    account_absent : bool;
        (** Whether no provider is connected — at least one provider needs auth
            yet none has a usable credential (09-auth.md §9). Drives the
            [account none — /login to connect] workspace line (12-home.md
            §States). *)
    warning : string option;
        (** One dangerous-config warning (sandbox danger-full-access or a
            permission bypass), rendered as the stage's one loud line
            (12-home.md §Degraded); [None] when the config is safe. *)
  }
  (** The type for the live workspace facts. *)

  val relative_age : now:Spice_session.Time.t -> Spice_session.Time.t -> string
  (** [relative_age ~now t] is [t]'s age relative to [now] as a terse label:
      ["just now"], ["3m ago"], ["2h ago"], ["4d ago"], ["2w ago"], ["5mo ago"],
      or ["1y ago"]. A [t] after [now] (clock skew) reads ["just now"]. *)
end

(** The lockup animation state (08-brand.md §Motion). *)
module Motion : sig
  type t
  (** The type for the lockup playback state. *)

  val init : reduced:bool -> t
  (** [init ~reduced] starts the motion: the pour on the first paint, or the
      static lockup with no timers when [reduced] (reduced-motion honored via
      [SPICE_REDUCED_MOTION], read by the runtime). *)

  val tick : t -> t
  (** [tick t] advances one frame: the pour cycles in full — the nine pour
      frames, then a beat's hold on the settled heap — and repeats (08-brand.md
      §Motion). Frozen and static states are unchanged. *)

  val freeze : t -> t
  (** [freeze t] pins the lockup to its static form for the rest of the process
      — the first-keystroke transition (12-home.md §Liveness). Idempotent. *)

  val animating : t -> bool
  (** [animating t] is [true] while a frame timer is warranted (the pour
      looping) — [false] once frozen or when reduced motion holds it static, so
      no timer runs after the freeze. *)

  val lockup_rows : t -> string list
  (** [lockup_rows t] is the two lockup rows at the current frame: the wordmark
      with its grain and mound region substituted for the current pour figure.
      The static frame is {!Theme.lockup} byte-for-byte. *)
end

val composer_width : int -> int
(** [composer_width width] is the inset composer's column budget on a
    [width]-column stage: 60, shrinking with a narrow stage and never below 24
    (12-home.md §Layout). The shell passes it to {!Composer.render} so the
    frame's hand-rolled rules span exactly the inset box. *)

val stage :
  snapshot:Snapshot.t ->
  brief:Brief.t option ->
  notice:string list ->
  motion:Motion.t ->
  composer:'msg Mosaic.t option ->
  width:int ->
  rows:int ->
  'msg Mosaic.t
(** [stage ~snapshot ~brief ~notice ~motion ~composer ~width ~rows] is the whole
    region above the footer: the centered lockup (with [motion]'s frame) and
    facts line, an optional [notice] blockquote (a [▎] accent bar; the committed
    welcome grammar styles its lead line default fg with "spice" an accent atom
    and its supporting lines muted) when non-empty, the inset [composer] at the
    visual center — hidden when [composer] is [None], as when a panel takes the
    region below (doc/plans/tui-next-surfaces.md §Panel geometry) — and the
    workspace block centered as a unit directly beneath it. [brief] is [None]
    until the first workspace load lands — the block is then a single muted
    spinner line rather than a blank region — and [Some] thereafter; the one
    dangerous-config [warning] renders as the stage's single loud line below the
    block. [width] and [rows] drive the session-title truncation and the
    short-terminal bottom-up shedding of the workspace facts.

    The brand's top offset is pinned to its centered idle position — a single px
    gap computed from [rows] against a composer-independent idle content height
    — so the lockup holds still when a panel or the help sheet grows from below
    rather than jumping upward (12-home.md §Layout); the workspace block and the
    warning belong to the idle stage, so they drop while a panel owns the region
    below, leaving the pinned brand and notice above it. Under height pressure
    the stage sheds top-down so the footer (the shell's own row) always renders:
    the notice and workspace fold below 16 rows, the warning a little later, and
    the composer only under 10 rows, surviving longest with the footer
    (12-home.md §States). *)
