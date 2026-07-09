(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session goal artifacts and the goal continuation boundary.

    A goal is a durable session objective that outlives a single turn. It is
    host product state kept beside a session's replay log, not {!Spice_session}
    transcript state: the transcript records the turns the goal caused, while
    this value records the objective, its lifecycle, and its usage accounting.

    At most one goal exists per session; storage owns that key scheme. The user
    owns the lifecycle verbs — {!set}, {!edit}, {!pause}, {!resume}, {!clear} —
    and the model owns exactly one claim through the {!Call.HOST_TOOL} surface
    ({!tool}, {!decode}): an {!Update.t} reporting the goal complete or blocked,
    applied with {!apply}. Construction and transitions are pure and report
    invariant failures as diagnostic strings. *)

module Id : sig
  (** Non-empty stable goal identifiers. *)

  type t
  (** The type for goal identifiers. The string form is the JSON value. *)

  val of_string : string -> (t, string) result
  (** [of_string s] is [s] as a goal id. Errors when [s] is empty. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representation. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps goal ids to JSON strings, funneling through {!of_string}. *)
end

module Status : sig
  (** Goal lifecycle status.

      {!Active} is the pursued state and the only state continuation may launch
      from. {!Paused}, {!Blocked}, and {!Budget_limited} are stopped but
      resumable by the user; {!Completed} and {!Cleared} are terminal. Unlike
      {!Plan.Status}, statuses carry no transition times — a goal moves back and
      forth (pause, resume), so the artifact records the latest transition in
      {!Goal.updated_at}. *)

  type t = private
    | Active
    | Paused
    | Blocked of { reason : string option }
    | Budget_limited
    | Completed of { summary : string option }
    | Cleared

  val active : t
  (** [active] is a pursued goal. *)

  val paused : t
  (** [paused] is a user-paused goal. *)

  val blocked : ?reason:string -> unit -> (t, string) result
  (** [blocked ?reason ()] is a blocked status. Errors when [reason] is present
      and empty. *)

  val budget_limited : t
  (** [budget_limited] is a goal stopped by its token budget. *)

  val completed : ?summary:string -> unit -> (t, string) result
  (** [completed ?summary ()] is a completed status. Errors when [summary] is
      present and empty. *)

  val cleared : t
  (** [cleared] is a user-cleared goal. *)

  val is_terminal : t -> bool
  (** [is_terminal t] is [true] iff [t] is {!Completed} or {!Cleared}. *)

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
(** The type for a session goal.

    Invariants: [objective] is non-empty; [token_budget] is absent or positive;
    [tokens_used], [time_used_ms], and [continuation_turns] are non-negative;
    {!Status.Budget_limited} has a token budget exhausted by [tokens_used];
    {!updated_at} is at or after {!created_at}; blocked reasons and completion
    summaries are absent or non-empty. *)

val set :
  id:Id.t ->
  session:Spice_session.Id.t ->
  objective:string ->
  ?token_budget:int ->
  created_at:Spice_session.Time.t ->
  unit ->
  (t, string) result
(** [set ~id ~session ~objective ?token_budget ~created_at ()] is a fresh
    {!Status.Active} goal with zero usage. Errors when [objective] is empty or
    [token_budget] is not positive. *)

val id : t -> Id.t
(** [id t] is [t]'s goal id. *)

val session : t -> Spice_session.Id.t
(** [session t] is the session that owns [t]. *)

val objective : t -> string
(** [objective t] is the verbatim user objective. It is user data: inject it
    delimited, as the task to pursue, never as higher-priority instructions. *)

val status : t -> Status.t
(** [status t] is [t]'s lifecycle status. *)

val token_budget : t -> int option
(** [token_budget t] is [t]'s optional token budget. *)

val tokens_used : t -> int
(** [tokens_used t] is the tokens accrued by [t]'s goal turns. *)

val remaining_tokens : t -> int option
(** [remaining_tokens t] is [token_budget - tokens_used], floored at zero, when
    [t] is budgeted. *)

val time_used_ms : t -> int
(** [time_used_ms t] is the active wall-clock milliseconds accrued by [t]'s goal
    turns. Paused and idle time never accrues. *)

val continuation_turns : t -> int
(** [continuation_turns t] is how many automatic continuation turns [t] has
    caused. *)

val created_at : t -> Spice_session.Time.t
(** [created_at t] is [t]'s creation time. *)

val updated_at : t -> Spice_session.Time.t
(** [updated_at t] is the time of [t]'s latest transition or accounting update,
    or {!created_at} for a fresh goal. *)

val is_unfinished : t -> bool
(** [is_unfinished t] is [true] iff {!Status.is_terminal} [t]'s status is
    [false]. An unfinished goal blocks {!set}ting a new one. *)

val is_active : t -> bool
(** [is_active t] is [true] iff [t] is {!Status.Active} — the only state
    continuation may launch from. *)

val may_update : t -> bool
(** [may_update t] is [true] iff the model may report on [t]: {!Status.Active}
    or {!Status.Budget_limited}. Paused and blocked goals are user territory;
    the [update_goal] tool is not offered for them. *)

(** {1:transitions Transitions}

    All transitions error with a diagnostic when the current status does not
    admit them, and stamp {!updated_at} with their time, which must be at or
    after {!created_at}. *)

val pause : paused_at:Spice_session.Time.t -> t -> (t, string) result
(** [pause ~paused_at t] pauses an {!Status.Active} goal. *)

val resume :
  resumed_at:Spice_session.Time.t ->
  ?token_budget:int ->
  t ->
  (t, string) result
(** [resume ~resumed_at ?token_budget t] reactivates a {!Status.Paused},
    {!Status.Blocked}, or {!Status.Budget_limited} goal. [token_budget] replaces
    the budget when present; it must be positive but may be below
    {!tokens_used}, in which case the host limits the goal again at the next
    boundary. *)

val edit :
  objective:string -> edited_at:Spice_session.Time.t -> t -> (t, string) result
(** [edit ~objective ~edited_at t] replaces an unfinished goal's objective in
    place, leaving its status untouched. Errors when [objective] is empty. *)

val clear : cleared_at:Spice_session.Time.t -> t -> (t, string) result
(** [clear ~cleared_at t] clears an unfinished goal. *)

val complete :
  completed_at:Spice_session.Time.t ->
  ?summary:string ->
  t ->
  (t, string) result
(** [complete ~completed_at ?summary t] completes an {!Status.Active} or
    {!Status.Budget_limited} goal. Errors on an empty present [summary]. *)

val block :
  blocked_at:Spice_session.Time.t -> ?reason:string -> t -> (t, string) result
(** [block ~blocked_at ?reason t] blocks an {!Status.Active} or
    {!Status.Budget_limited} goal. Errors on an empty present [reason]. *)

val limit_budget : limited_at:Spice_session.Time.t -> t -> (t, string) result
(** [limit_budget ~limited_at t] stops a budgeted {!Status.Active} goal as
    {!Status.Budget_limited}. Errors when [t] has no budget, still has remaining
    budget, or is not active. This is the host's boundary transition; the model
    never requests it. *)

val record_turn :
  at:Spice_session.Time.t ->
  tokens:int ->
  active_ms:int ->
  continuation:bool ->
  t ->
  (t, string) result
(** [record_turn ~at ~tokens ~active_ms ~continuation t] accrues one settled
    goal turn: [tokens] onto {!tokens_used}, [active_ms] onto {!time_used_ms},
    and one {!continuation_turns} when [continuation]. Errors on negative
    [tokens] or [active_ms]. Interrupted and budget-limited turns still accrue,
    and so does the turn that completed the goal — it settles after the
    transition — so totals stay honest. Accounting never changes status. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same goal. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps goals to JSON objects, funneling through the constructors. *)

(** {1:origin Turn origin}

    Continuation turns are visibly distinct from user turns: the turn record
    carries {!turn_origin} the same way it carries its mode — an uninterpreted
    stored string with one degrade policy, so projections never guess from
    message text. *)

val turn_origin : string
(** [turn_origin] is the {!Spice_session.Turn.origin} spelling recorded on goal
    continuation turns. *)

val is_continuation_turn : Spice_session.Turn.t -> bool
(** [is_continuation_turn turn] is [true] iff [turn] records {!turn_origin}.

    This is the single degrade policy for the uninterpreted [Turn.origin]
    string: an unknown or absent spelling is a user-initiated turn. *)

(** {1:host_tool Host tool} *)

module Update : sig
  (** Decoded model goal reports.

      An update is the checked payload of {!tool}: the model's claim that the
      goal is complete or blocked, with an optional short summary. The host
      applies it to the stored artifact with {!apply}. *)

  type t =
    | Complete of { summary : string option }
    | Blocked of { summary : string option }
        (** The type for a checked [update_goal] request. *)

  val make : status:string -> ?summary:string -> unit -> (t, string) result
  (** [make ~status ?summary ()] is a checked update. [status] must be
      ["complete"] or ["blocked"]; [summary] must be non-empty when present.
      This is the single validation path; {!jsont} and {!decode} funnel through
      it. *)

  val summary : t -> string option
  (** [summary t] is [t]'s optional model-authored summary. Status output must
      redact it like a title. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s status spelling, ["complete"] or ["blocked"]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same update. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps updates to JSON objects, funneling through {!make}. *)
end

val apply : now:Spice_session.Time.t -> Update.t -> t -> (t, string) result
(** [apply ~now update t] transitions [t] by the model's report: {!complete} for
    {!Update.Complete}, {!block} for {!Update.Blocked}, the summary carried into
    the status. The transition preconditions apply — a goal the user paused or
    cleared mid-turn rejects the update, and the caller answers the model with
    that diagnostic. *)

val name : string
(** [name] is the model-visible goal update tool name. *)

val tool : Spice_llm.Tool.t
(** [tool] is the model-visible goal update tool declaration. *)

val decode : Spice_llm.Tool.Call.t -> (Update.t, string) result
(** [decode call] decodes [call]'s input as a goal update. Errors with a
    diagnostic when [call] does not target {!name} or its payload fails shape or
    update validation. *)
