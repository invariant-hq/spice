(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The footer (04-header-footer.md §2).

    The always-visible bottom row of live facts, byte-identical across the
    home→chat transition (12-home.md §Principle 1): the cwd (left-truncated to
    keep the tail), the compact model, and the dune connectivity verdict, with
    [? for shortcuts] pinned right — dropped when the row is too narrow to hold
    it beside the facts (§4), pill or no pill. There is no version segment — the
    banner carries it.

    On top of that idle row the footer grows three composer-facing states, all
    passed as pure data by the shell (which owns the underlying state):

    - the {!type-posture} pill, leftmost, ahead of the cwd (§4);
    - a composer {!type-input_mode} badge, which claims the right hint slot and
      replaces the fact segments with the mode's key hints
      (03-ia-screens-overlays.md §Composer input modes).

    The [dune:] substring is present in every idle state; the pty harness waits
    on it as the boot marker. *)

(** {1:states Composer states} *)

(** The approval posture the pill reports (§4). The shell owns the state and
    cycles it with [shift+tab]. *)
type posture =
  | Ask  (** The default: no pill. *)
  | Accept_edits  (** [⏵⏵ accept edits on (shift+tab to cycle)] in [accent]. *)
  | Never_ask  (** [⏵⏵ never ask on (shift+tab to cycle)] in [error]. *)

(** A composer input mode. When set, the right slot becomes the mode badge and
    the left fact segments become the mode's key hints. *)
type input_mode =
  | Shell  (** ["!"] shell mode: badge [! shell] in [warning]. *)
  | History_search
      (** ctrl+r search: badge [⌕ history] in the history color. *)

(** {1:view View} *)

val view :
  ?posture:posture ->
  ?input_mode:input_mode ->
  ?agents:int ->
  ?home_badge:string ->
  ?account_absent:bool ->
  Snapshot.t ->
  dune:Spice_ocaml_dune.Rpc.Instance.Health.t ->
  width:int ->
  _ Mosaic.t
(** [view ?posture ?input_mode snapshot ~dune ~width] renders the
    footer at [width] columns. With no optional arguments it is the idle fact
    row (the pre-existing call [view snapshot ~dune ~width] is unchanged).

    - [posture] defaults to {!Ask} and, when set, draws the pill leftmost. It
      participates in the width budget; when the pill, cwd, and hint cannot
      coexist the pill wins — the [? for shortcuts] hint drops first, then facts
      per §2's truncation order.
    - [input_mode] defaults to none. When set, the right slot shows the mode
      badge and the left segment shows the mode's key hints in [faint] instead
      of the cwd and facts.
    - [agents] is the count of live child subagent runs; when positive it draws
      a muted [* N agents] fact between the model and the dune verdict
      (04-header-footer.md §2 [agent] slot; [*] is the IA agent-thread glyph).
      Omitted or [0] draws nothing. Only the idle fact row carries it — an input
      mode takeover hides the facts entirely.
    - [home_badge] defaults to none. When set (a drilled-in thread's footer,
      03-ia §Agent threads), it claims the right slot with the way-home badge in
      [accent] — e.g. [⏴ @explore · esc for main] — ahead of the [? for shortcuts]
      hint, which it replaces. An input mode takeover still wins the slot, but
      those never coexist with a drilled-in thread.
    - [account_absent] defaults to [false]. When [true] (no provider connected),
      a loud [! not logged in · /login] leads the left segment and is never
      dropped, the optional facts degrading around it (09-auth.md §9). Only the
      idle fact row carries it.

    [dune] drives the [dune: ✓]/[dune: ✗] verdict, which reflects connectivity
    only (04-header-footer.md §7). The context meter is the brand heap at five
    heights and renders only once a turn has used tokens and the model window is
    known; at the home, before the first turn, no meter renders (12-home.md
    footer). Segment widths are estimated and the cwd pre-truncated in OCaml,
    never via [~truncate] (the Mosaic flex-truncate quirk). *)
