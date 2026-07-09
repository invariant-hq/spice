(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** One rendering vocabulary for subagent threads.

    Every threads surface — the below-footer switcher strip, the drilled-in
    thread's chrome, the parent's settled-notice line — draws its status glyph,
    style, label, and fact strings from here, so the same run state always looks
    the same (doc/plans/tui-next-threads.md §4.1). It is the tui-next analog of
    the old TUI's [Subagent_view]; the old module binds the retired
    [Theme]/[Glyph], so its logic is ported rather than shared.

    This module is pure: every value is a function of a {!Spice_protocol} record
    (and a clock passed as [~now]), reads no host, and renders formatting
    (glyphs, ages, ellipsis, token compaction), never facts. *)

(** {1 Status} *)

type status =
  | Queued
  | Running
  | Blocked
  | Completed
  | Failed
  | Interrupted
      (** The surface-level run state — the persisted
          {!Spice_protocol.Subagent_run.Status.t} lifecycle projected to what
          renders. A cancelled run is {!Interrupted}: interruption reads as
          neutral, not failure. *)

val of_run_status : Spice_protocol.Subagent_run.Status.t -> status
(** [of_run_status status] is the persisted lifecycle [status] as a surface
    state. *)

val of_run : Spice_protocol.Subagent_run.t -> status
(** [of_run run] is [of_run_status] of [run]'s status. *)

val glyph : status -> string
(** [glyph status] is the status mark: [•] running and blocked, [✓] completed,
    [✗] failed, [◌] queued and interrupted (00-overview.md §Glyph vocabulary).
*)

val style : status -> Mosaic.Ansi.Style.t
(** [style status] is the outcome color for [glyph status]: running
    {!Theme.running}, blocked and interrupted {!Theme.warning}, completed
    {!Theme.success}, failed {!Theme.error}, queued {!Theme.muted}. *)

val word : status -> string
(** [word status] is the lowercase status word (["running"], ["blocked"], …). *)

(** {1 Roles and text} *)

val role_label : Spice_protocol.Subagent.Role.t -> string
(** [role_label role] is the capitalized role name, or ["Subagent"] when the
    role spelling is empty. *)

val compact : string -> string
(** [compact text] collapses whitespace runs (including newlines) in [text] to
    single spaces, for one-line task and summary rendering. *)

val clip : max:int -> string -> string
(** [clip ~max text] truncates [text] to at most [max] bytes with a trailing
    ["…"], never splitting a UTF-8 scalar. Pre-truncation in OCaml, not Mosaic
    [truncate] — flex-truncated text measures at its prior layout width (project
    memory, the flex-truncate quirk). *)

(** {1 Facts} *)

val duration : ms:int64 -> string
(** [duration ~ms] renders a span: ["45s"], ["3m 12s"], ["1h 57m 23s"]. Negative
    spans clamp to ["0s"]. *)

val elapsed :
  now:Spice_session.Time.t -> Spice_protocol.Subagent_run.t -> string option
(** [elapsed ~now run] is the run's age: for a running or blocked run, the span
    from creation to [now]; for a terminal run, creation to the terminal
    transition. [None] while queued. The creation anchor stands in for a start
    anchor because terminal statuses do not retain a started anchor and queued
    time is negligible. *)

val tokens : Spice_protocol.Subagent_run.Usage.t -> string
(** [tokens usage] is the CC-style output-tokens fact [↓ 12.3k tokens] from
    [usage]'s completion tokens (decision 10: the ledger keeps the split, every
    rendering shows the single output figure), k-compacted ([845], [1.3k],
    [23.1k]). *)

val settled_fact : Spice_protocol.Subagent_run.Status.t -> string option
(** [settled_fact status] is the settled outcome detail: a completed run's
    compacted summary, ["failed: <message>"], ["blocked: <blocker>"], or
    ["interrupted"]. [None] while queued or running. *)

val settled_line :
  Spice_protocol.Subagent_run.t -> string * [ `Status | `Problem ]
(** [settled_line run] is the parent transcript's settled-notice text for [run],
    in the spec grammar (02-tools.md §Subagents; subagent-tui.md decision 9;
    doc/plans/tui-next-threads.md §2.5): [● Agent "<task>" <phrase> · <facts>],
    where the task is quoted, [phrase] is ["finished"] / ["was interrupted"] /
    ["failed: <message>"], and the facts are usage and duration joined by
    {!Theme.separator}. A completed run's summary hangs clipped on a second
    line. The severity is [`Problem] only for failures; cancellation is neutral.
*)

(** {1 Attention} *)

(** A thread's attention state — a fact beyond the status glyph that a row and
    the manage view surface (subagent-tui.md §5.6). Write-seat-queued (the Build
    role) is out of this iteration. *)
type attention =
  | Awaiting_reply  (** Parked on a [message_parent] ask. *)
  | Permission_blocked  (** Parked on a permission escalation. *)

val attention_label : attention -> string
(** [attention_label a] is the row fact: [✉ waiting on reply] for
    {!Awaiting_reply}, [⋯ waiting on permission] for {!Permission_blocked}. *)
