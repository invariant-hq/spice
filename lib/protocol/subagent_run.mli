(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Subagent run records.

    A run links a parent session tool call to a child session: the parent
    transcript holds an ordinary {!Subagent.tool} call and eventual result, the
    child runs in its own {!Spice_session.t}, and this value records lineage,
    role, lifecycle, and handoff. It is host product workflow state, not
    {!Spice_session} replay state.

    A run embeds a decoded {!Subagent.Spawn.t}. Construction and lifecycle
    transitions are pure and report invariant failures as diagnostic strings.
    The tagged-lifecycle {!Status} shares its monotonicity guard with
    {!Plan.Status}. *)

module Usage : sig
  (** Child run outcome facts, recorded at the terminal transition.

      Facts of a run spice owns — ledger state, not a derived cache
      (doc/plans/subagent-tui.md §8.2). Absent on runs recorded before the facts
      existed. *)

  type t = { prompt_tokens : int; completion_tokens : int; tool_uses : int }
  (** The type for child run usage. All counts are non-negative; decoding
      rejects negatives. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] carry the same counts. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps usage to a JSON object; negative counts are a decode error.
  *)
end

module Status : sig
  (** Subagent run lifecycle status.

      {!Queued} is the initial state. {!Running} and {!Blocked} are
      non-terminal. {!Completed}, {!Failed}, and {!Cancelled} are terminal. The
      enclosing run transitions enforce the lifecycle graph. Terminal statuses
      carry the run's {!Usage.t} when the recorder had it. *)

  type t = private
    | Queued
    | Running of { started_at : Spice_session.Time.t }
    | Blocked of { blocked_at : Spice_session.Time.t; blocker : string }
    | Completed of {
        completed_at : Spice_session.Time.t;
        summary : string;
        usage : Usage.t option;
      }
    | Failed of {
        failed_at : Spice_session.Time.t;
        message : string;
        usage : Usage.t option;
      }
    | Cancelled of {
        cancelled_at : Spice_session.Time.t;
        usage : Usage.t option;
      }

  val queued : t
  (** [queued] is a run that has not started. *)

  val running : started_at:Spice_session.Time.t -> t
  (** [running ~started_at] is a running status. *)

  val blocked :
    blocked_at:Spice_session.Time.t -> blocker:string -> (t, string) result
  (** [blocked ~blocked_at ~blocker] is a blocked status. Errors when [blocker]
      is empty. *)

  val completed :
    completed_at:Spice_session.Time.t ->
    summary:string ->
    ?usage:Usage.t ->
    unit ->
    (t, string) result
  (** [completed ~completed_at ~summary ?usage ()] is a completed status. Errors
      when [summary] is empty. *)

  val failed :
    failed_at:Spice_session.Time.t ->
    message:string ->
    ?usage:Usage.t ->
    unit ->
    (t, string) result
  (** [failed ~failed_at ~message ?usage ()] is a failed status. Errors when
      [message] is empty. *)

  val cancelled :
    cancelled_at:Spice_session.Time.t -> ?usage:Usage.t -> unit -> t
  (** [cancelled ~cancelled_at ?usage ()] is a cancelled status — the neutral
      terminal outcome of an interrupt, distinct from {!Failed} so an
      interrupted child does not read as an error. *)

  val transition_time : t -> Spice_session.Time.t option
  (** [transition_time t] is the time of [t]'s non-queued transition. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable status spelling. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same status. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps statuses to JSON values. *)
end

type t
(** The type for a subagent run record.

    Invariants: [parent_call_id] is non-empty; [depth] is non-negative;
    non-queued lifecycle times are at or after {!created_at}; [spawn] satisfies
    {!Subagent.Spawn.t} invariants. *)

val make :
  child:Spice_session.Id.t ->
  parent:Spice_session.Id.t ->
  parent_turn:Spice_session.Turn.Id.t ->
  parent_call_id:string ->
  spawn:Subagent.Spawn.t ->
  depth:int ->
  created_at:Spice_session.Time.t ->
  unit ->
  (t, string) result
(** [make ...] is a queued child run record. Errors when [parent_call_id] is
    empty or [depth] is negative. *)

val child : t -> Spice_session.Id.t
(** [child t] is the child session id. *)

val parent : t -> Spice_session.Id.t
(** [parent t] is the parent session id. *)

val parent_turn : t -> Spice_session.Turn.Id.t
(** [parent_turn t] is the parent turn that requested the child. *)

val parent_call_id : t -> string
(** [parent_call_id t] is the parent host-tool call id. *)

val spawn : t -> Subagent.Spawn.t
(** [spawn t] is the original spawn request. *)

val role : t -> Subagent.Role.t
(** [role t] is [spawn t]'s role. *)

val task : t -> string
(** [task t] is [spawn t]'s task. *)

val depth : t -> int
(** [depth t] is the child depth below the root session; root-spawned children
    normally have depth [1]. *)

val status : t -> Status.t
(** [status t] is the run lifecycle status. *)

val created_at : t -> Spice_session.Time.t
(** [created_at t] is the run creation time. *)

val updated_at : t -> Spice_session.Time.t
(** [updated_at t] is the latest transition time, or {!created_at} while queued.
*)

val start : started_at:Spice_session.Time.t -> t -> (t, string) result
(** [start ~started_at t] marks queued run [t] running. Errors unless [t] is
    queued, or when [started_at] is before {!created_at} [t]. *)

val block :
  blocked_at:Spice_session.Time.t -> blocker:string -> t -> (t, string) result
(** [block ~blocked_at ~blocker t] marks a running or blocked run blocked.
    Errors on empty [blocker], a queued or terminal [t], or a time before
    {!created_at} [t]. *)

val complete :
  completed_at:Spice_session.Time.t ->
  summary:string ->
  ?usage:Usage.t ->
  t ->
  (t, string) result
(** [complete ~completed_at ~summary ?usage t] marks a running or blocked run
    completed. Errors on empty [summary], a queued or terminal [t], or a time
    before {!created_at} [t]. *)

val fail :
  failed_at:Spice_session.Time.t ->
  message:string ->
  ?usage:Usage.t ->
  t ->
  (t, string) result
(** [fail ~failed_at ~message ?usage t] marks a queued, running, or blocked run
    failed. Errors on empty [message], a terminal [t], or a time before
    {!created_at} [t]. *)

val cancel :
  cancelled_at:Spice_session.Time.t -> ?usage:Usage.t -> t -> (t, string) result
(** [cancel ~cancelled_at ?usage t] marks a queued, running, or blocked run
    cancelled. Errors on a terminal [t] or a time before {!created_at} [t]. *)

val resume : resumed_at:Spice_session.Time.t -> t -> (t, string) result
(** [resume ~resumed_at t] marks a blocked or terminal run running again: a
    message resumed the settled child session (doc/plans/subagent-tui.md §5.6).
    The one deliberate backward edge in the otherwise forward-only lifecycle;
    the run keeps its identity because the run key is the child session, and the
    next terminal transition re-records usage over the whole session. Errors on
    a queued or running [t], or a time before {!created_at} [t]. *)

val usage : t -> Usage.t option
(** [usage t] is the terminal usage record, when [t] settled with one. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same run. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps run records to JSON objects, funneling through the
    constructors. *)
