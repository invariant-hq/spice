(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Goal lifecycle verbs, accounting, and the continuation decision.

    This module is the host side of the goal contract ({!Spice_protocol.Goal}):
    the user lifecycle verbs the CLI and TUI submit, the per-turn accounting and
    safety transitions applied when a goal turn settles, the context injection
    (continuation prompt and ephemeral notices), and the continuation decision
    both drivers consult.

    Driving stays surface-owned. {!Runner.execute} interprets one command per
    call and each surface owns its loop, so this module never launches a turn:
    {!continuation} decides and re-validates, the driver builds the turn — with
    {!Spice_protocol.Goal.turn_origin} — and submits it. Because {!continuation}
    re-reads the artifact at decision time, a lifecycle verb that lands between
    a turn's settle and the next launch wins; a driver must call it immediately
    before launching, never ahead of an interrupt. *)

(** {1:verbs Lifecycle verbs}

    Verbs are load-transition-save over the stored artifact. State refusals —
    the goal does not admit the verb, or a set collides with an unfinished goal
    — are {!Refused} with the user-facing diagnostic; storage failures are
    {!Storage}. Refusals mutate nothing. *)

(** The type for a failed lifecycle verb. *)
type verb_error = Refused of string | Storage of Artifacts.Error.t

val verb_error_message : verb_error -> string
(** [verb_error_message e] is a human-readable diagnostic for CLI and TUI
    output. *)

val set_goal :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  id:Spice_protocol.Goal.Id.t ->
  session:Spice_session.Id.t ->
  objective:string ->
  ?token_budget:int ->
  now:Spice_session.Time.t ->
  unit ->
  (Spice_protocol.Goal.t, verb_error) result
(** [set_goal ~fs ~root ~id ~session ~objective ?token_budget ~now ()] sets
    [session]'s goal. An unfinished existing goal is {!Refused} naming the edit
    and clear recovery verbs; a terminal one is replaced in place — V1 keeps no
    goal history. *)

val edit_goal :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  session:Spice_session.Id.t ->
  objective:string ->
  now:Spice_session.Time.t ->
  (Spice_protocol.Goal.t, verb_error) result
(** [edit_goal ~fs ~root ~session ~objective ~now] replaces the unfinished
    goal's objective in place, leaving its status untouched. The driver
    publishes {!objective_updated_notice} so a running turn learns of the
    change. *)

val pause_goal :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  session:Spice_session.Id.t ->
  now:Spice_session.Time.t ->
  (Spice_protocol.Goal.t, verb_error) result
(** [pause_goal ~fs ~root ~session ~now] pauses the active goal. *)

val resume_goal :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  session:Spice_session.Id.t ->
  ?token_budget:int ->
  now:Spice_session.Time.t ->
  unit ->
  (Spice_protocol.Goal.t, verb_error) result
(** [resume_goal ~fs ~root ~session ?token_budget ~now ()] reactivates a paused,
    blocked, or budget-limited goal, replacing the budget when [token_budget] is
    present. *)

val clear_goal :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  session:Spice_session.Id.t ->
  now:Spice_session.Time.t ->
  (Spice_protocol.Goal.t, verb_error) result
(** [clear_goal ~fs ~root ~session ~now] clears the unfinished goal. *)

(** {1:context Context injection}

    The objective is user data; every rendering below delimits it and frames it
    as the task to pursue. Notices are ephemeral ({!Notice_queue}) and never
    persisted. *)

val continuation_prompt : Spice_protocol.Goal.t -> string
(** [continuation_prompt goal] is the host-authored input of a continuation
    turn: the verbatim objective, budget accounting when budgeted, and the
    standing continuation, fidelity, completion-audit, and blocked-audit rules.
    It is rendered fresh from the artifact for every continuation, so it
    survives compaction and objective edits. *)

val context_notice : Spice_protocol.Goal.t -> Spice_protocol.Notice.t
(** [context_notice goal] is the compact goal reminder a driver publishes when
    starting a user-initiated turn while [goal] is unfinished. Continuation
    turns must not publish it — the continuation prompt already carries the
    goal. *)

val objective_updated_notice : Spice_protocol.Goal.t -> Spice_protocol.Notice.t
(** [objective_updated_notice goal] tells a running turn the objective was
    edited, with the new objective delimited. *)

(** {1:accounting Accounting and safety} *)

val turn_tokens :
  before:Spice_session.Metrics.t -> after:Spice_session.Metrics.t -> int
(** [turn_tokens ~before ~after] is the token spend between two cumulative
    metrics snapshots taken at a turn's boundaries: the lane-sum delta, floored
    at zero. *)

val budget_watch :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  session:Spice_session.Id.t ->
  notices:Notice_queue.t ->
  Spice_protocol.Event.t ->
  unit
(** [budget_watch ~fs ~root ~session ~notices] is a stateful event observer that
    publishes the budget wind-down notice into [notices] the first time a build
    turn's in-flight spend crosses the goal's remaining budget, so the model
    wraps up mid-turn instead of overshooting unboundedly. It reloads the goal
    at each turn start and is inert when the goal is absent, unbudgeted, or not
    pursued. Compose it into the run hooks with {!Session.with_observe}. *)

val settle :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  now:Spice_session.Time.t ->
  document:Spice_session_store.Document.t ->
  outcome:Spice_protocol.Outcome.t ->
  tokens:int ->
  active_ms:int ->
  (Spice_protocol.Goal.t option, Artifacts.Error.t) result
(** [settle ~fs ~root ~now ~document ~outcome ~tokens ~active_ms] applies one
    settled command to the stored goal and returns the goal as stored after it.

    A {!Spice_protocol.Outcome.Waiting} settle and a non-build turn change
    nothing. A finished build goal turn accrues [tokens] and [active_ms] —
    interrupted and failed turns included, and the turn that completed the goal
    too, so totals stay honest — then, when the goal is still unfinished,
    applies the safety transition its outcome demands: an interrupt pauses the
    goal, a failure blocks it (automatic continuation must not loop through
    provider errors), and a clean end past the token budget stops it as
    budget-limited. *)

(** {1:continuation Continuation} *)

val continuation :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  session:Spice_session.Id.t ->
  mode:Spice_protocol.Mode.t ->
  Spice_protocol.Outcome.t ->
  ((Spice_protocol.Goal.t * string) option, Artifacts.Error.t) result
(** [continuation ~fs ~root ~session ~mode outcome] is the continuation
    decision: [Some (goal, prompt)] exactly when [mode] is {!Mode.Build},
    [outcome] finished cleanly ({!Turn.Outcome.Completed} or
    {!Turn.Outcome.Step_limit}), and the goal — {b re-read here}, which is the
    launch revalidation — is still active. The driver builds a build-mode turn
    from [prompt] with {!Spice_protocol.Goal.turn_origin} and submits it
    immediately; parked, interrupted, and failed settles are [None] by
    construction. *)
