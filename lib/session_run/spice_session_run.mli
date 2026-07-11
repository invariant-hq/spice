(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Spice_session

(** Pure run planning for active session turns.

    [spice.session.run] is the pure planner for the model/tool loop over a
    durable session.
    It validates and appends session events, builds model requests, dispatches
    decoded executable tool calls, applies permission policy, and reports the
    next external boundary. It does not call the model, run tools, save
    sessions, or own workspace state.

    Hosts call {!start}, {!resume}, or a continuation function and persist the
    checked transition with one of two strategies:
    - an append store appends {!Step.events} to the input session and verifies
      that the saved result represents {!Step.session};
    - a whole-document store saves {!Step.session} and uses {!Step.events}
      only as the transition delta for observation.

    The chosen durable write must complete before the host interprets
    {!Step.next} and feeds the external result back with {!accept_response},
    {!finish_tool}, {!resolve_permission}, or {!answer_host_tool}.

    Every function that starts or advances a run requires
    {!Metadata.Status.Active}. It returns {!Error.Archived} or
    {!Error.Deleted} before planning any external effect otherwise.
    {!State.phase} is the parameter-free read-only execution projection and
    accepts every lifecycle status.

    The save-before-effect rule is part of the contract. In particular,
    {!Step.Run_tool} contains a durable {!Tool_claim.Started.t} event that
    must be saved before the executable tool call is run. If the host restarts
    after saving that event but before recording a result, later planning
    reports {!Step.Waiting} with {!Waiting.Tool_claim} and does not rerun the
    tool automatically. *)

module Error : sig
  (** Recoverable run-planning errors. *)

  type t =
    | Request of Spice_llm.Request.Error.t
        (** The active transcript could not become a model request. *)
    | Tool of Spice_tool.Error.t
        (** Tool dispatch failed before execution. *)
    | No_active_turn  (** The session has no active turn to advance. *)
    | Permission_not_pending of Permission.Id.t
        (** A permission answer referenced no pending permission request. *)
    | Tool_claim_not_pending of Tool_claim.Id.t
        (** A tool result referenced no pending durable tool claim. *)
    | Tool_call_not_pending of { call_id : string; name : string }
        (** A host-tool answer referenced no pending matching tool call. *)
    | Tool_result_mismatch of {
        expected_call_id : string;
        expected_name : string;
        actual_call_id : string;
        actual_name : string;
      }
        (** A host-tool answer result did not answer the waiting host-tool
            call. *)
    | Archived  (** The session is archived. *)
    | Deleted  (** The session is deleted. *)
    | State of State.Error.t
        (** Applying planned events or a continuation would violate session
            replay invariants. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. The wording is not
      stable machine-readable syntax; callers should match on [e]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

module Config : sig
  (** Immutable runtime inputs for deciding session steps. *)

  type t
  (** The type for checked executable tools, host-handled model-visible tools,
      permission policy, request prelude, and live safety step cap.

      A config carries no model client, scheduler, store, workspace, or
      mutable run state. *)

  val make :
    tools:Spice_tool.t list ->
    ?host_tools:Spice_llm.Tool.t list ->
    policy:Spice_permission.Policy.t ->
    ?prelude:Spice_llm.Request.Prelude.t ->
    ?safety_step_cap:int ->
    ?denial_message:(Spice_permission.Policy.Denial.t -> string) ->
    unit ->
    t
  (** [make ~tools ?host_tools ~policy ?prelude ?safety_step_cap
      ?denial_message ()] is a checked run config.

      [tools] are executable host capabilities. [host_tools] are model-visible
      tools whose calls block the run for product-owned host handling. A call
      is classified as host-handled by tool name before executable-tool
      dispatch. Their provider-facing declarations are cached and become the
      durable declaration snapshot of each newly accepted turn.

      [prelude] defaults to {!Spice_llm.Request.Prelude.empty} and is used for
      every model request built from this config. It does not become session
      transcript state.

      [safety_step_cap] defaults to [max_int] (effectively unbounded;
      interrupt is the safety valve). It is the default accepted limit for a
      new turn and may tighten an active turn, but cannot widen that turn's
      durable limit.

      [denial_message] renders the model-visible tool error text for a tool
      call denied by policy without review. It defaults to a stable generic
      message. The function must be deterministic, must not raise, and must
      return a non-empty string because its result becomes durable transcript
      state. Exceptions propagate from run planning, and an empty result
      raises [Invalid_argument] when the tool result is constructed.

      Raises [Invalid_argument] if [tools] contains duplicate tool names, if
      an executable tool cannot be projected to a model-visible declaration,
      if a host-tool name is duplicated or also used by an executable tool, or
      if [safety_step_cap] is not positive. *)

  val declarations : t -> Spice_llm.Tool.t list
  (** [declarations t] are the model-visible declarations accepted by a new
      turn: executable tools rendered as LLM declarations, then host tools,
      in declaration order. Active turns use their own durable snapshot. *)
end

module Step : sig
  (** Planned session transition plus the next external boundary. *)

  type t
  (** The type for a checked session transition.

      [events t] is the exact event suffix applied to the input session, and
      [session t] is the validated session after that suffix. An append store
      persists [events t] against the input document; a whole-document store
      persists [session t]. These are alternative representations of the same
      transition, not two updates to apply. The chosen write must complete
      before interpreting [next t]. Some steps append no events; callers still
      receive the session used to compute the boundary. *)

  (** The type for external boundaries after a planned transition. *)
  type next =
    | Request_model of Spice_llm.Request.t
        (** The active transcript is ready for the model.

            The host persists the checked transition, calls the model with the
            request, then continues with {!accept_response}. *)
    | Run_tool of { claim : Tool_claim.Started.t; call : Spice_tool.Call.t }
        (** An executable tool call is decoded, permitted, and claimed.

            [claim] has a deterministic id derived from the active turn and
            model tool-call id. The host persists the checked transition, runs
            [call] at most once, then continues with {!finish_tool}. *)
    | Waiting of Waiting.t
        (** The active turn is waiting for host or user input. Planning has
            not performed the waiting effect. *)
    | Finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
        (** The active turn reached a terminal outcome.

            [Completed] comes from a model response without tool calls.
            [Step_limit] is produced when the active turn has reached its
            model-response limit. [Interrupted] is produced by
            {!interrupt}. *)

  val events : t -> Event.t list
  (** [events t] are the durable events appended by [t]. *)

  val session : t -> session
  (** [session t] is the validated session after {!events} [t]. *)

  val next : t -> next
  (** [next t] is the next external boundary after persisting the checked
      transition [t]. *)

  val pp_next : Format.formatter -> next -> unit
  (** [pp_next ppf next] formats [next] for diagnostics. *)
end

val start :
  Config.t ->
  id:Turn.Id.t ->
  input:Turn.Input.t ->
  model:Spice_llm.Model.t ->
  ?options:Spice_llm.Request.Options.t ->
  ?mode:string ->
  ?origin:string ->
  ?max_steps:int ->
  session ->
  (Step.t, Error.t) result
(** [start config ~id ~input ~model ?options ?mode ?origin ?max_steps session]
    starts a turn in [session] and advances to the next external boundary.

    The complete declaration list and host-tool ownership subset are stamped
    from [config]. [options] defaults to {!Spice_llm.Request.Options.default}.
    [max_steps], when absent, uses [config]'s safety cap; a larger explicit
    value is clamped to that cap. The effective positive limit is recorded on
    the turn. [mode] and [origin], when present, are durable host metadata
    interpreted outside replay.

    The returned step includes the turn-started event and any immediately
    planned events, such as a permission request or tool claim. Returns
    {!Error.State} if the turn cannot be appended, for example because
    [session] already has an active turn. *)

val resume : Config.t -> session -> (Step.t, Error.t) result
(** [resume config session] advances [session]'s active turn to the next
    external boundary.

    Existing waiting states are reported unchanged. A ready transcript becomes
    {!Step.Request_model}, unless the accepted model-response limit or current
    safety cap is reached. A
    pending executable tool call is decoded, permission-checked, and either
    claimed, blocked for review, denied with a model-visible error result, or
    answered with a dispatch error result.

    Model requests use the active turn's durable declarations and host-tool
    ownership. [config] supplies the live prelude, executable implementations,
    permission policy, and denial rendering. A newly configured tool is not
    available until the next turn; a removed or changed executable fails
    through the ordinary tool-dispatch error path.

    Returns {!Error.No_active_turn} if [session] has no active turn. *)

val interrupt : ?reason:string -> session -> (Step.t, Error.t) result
(** [interrupt ?reason session] finishes [session]'s active turn as
    interrupted by cancellation.

    The host owns the cancellation signal; when it fires between planning
    steps, the host calls [interrupt] instead of continuing. The recorded
    outcome is [Interrupted] with [cancelled = true] and [reason], when
    present.

    Before finishing, every unanswered assistant tool call receives a
    synthesized interrupted tool result ([reason], or ["interrupted"] when
    absent), so the saved transcript stays provider-well-formed and the next
    turn's request is not rejected for missing tool results. A planned but
    unrun executable claim is finished with that result; a pending host-tool
    call or a not-yet-claimed executable call gets a direct tool result. This
    is the same error-result shape a normally interrupted tool records.

    Returns {!Error.No_active_turn} if [session] has no active turn. Raises
    [Invalid_argument] if [reason] is present and empty. *)

val fail : message:string -> session -> (Step.t, Error.t) result
(** [fail ~message session] finishes [session]'s active turn as failed.

    A turn whose drive cannot continue — a terminal provider error, an
    unexpected exception — must still reach a terminal event, or the turn stays
    active in the saved session forever and every later command is refused
    against it. The recorded outcome is {!Spice_session.Turn.Outcome.Failed}
    carrying [message].

    Like {!interrupt}, every unanswered assistant tool call first receives a
    synthesized error tool result, so the saved transcript stays
    provider-well-formed and the next turn's request is not rejected for
    missing tool results.

    This is not the cancellation path: a turn the user interrupted finishes
    through {!interrupt} and records [Interrupted].

    Returns {!Error.No_active_turn} if [session] has no active turn. Raises
    [Invalid_argument] if [message] is empty. *)

val accept_response :
  Config.t -> Spice_llm.Response.t -> session -> (Step.t, Error.t) result
(** [accept_response config response session] records [response] and advances
    to the next external boundary. If [response] has no tool calls, the step
    also finishes the active turn as completed.

    Returns {!Error.No_active_turn} if [session] has no active turn. Returns
    {!Error.State} if recording [response] or the completion event would
    violate session replay invariants. *)

val finish_tool :
  Config.t ->
  Tool_claim.Id.t ->
  Spice_tool.Output.t Spice_tool.Result.t ->
  session ->
  (Step.t, Error.t) result
(** [finish_tool config id result session] records [result] for pending claim
    [id] and advances to the next external boundary.

    Completed results become normal model-visible tool results. Failed and
    interrupted results become error tool results, including their message or
    reason and any encoded output text.

    Returns {!Error.Tool_claim_not_pending} if [id] is not pending. Returns
    {!Error.State} if recording the result would violate session replay
    invariants. *)

val resolve_permission :
  Config.t ->
  ?message:string ->
  ?via:Permission.Resolved.via ->
  Permission.Id.t ->
  Spice_permission.Policy.Review.answer ->
  session ->
  (Step.t, Error.t) result
(** [resolve_permission config ?message ?via id answer session] records
    [answer] for pending permission [id] and advances to the next external
    boundary.

    The permission-resolved event is part of {!Step.events}. Denying a
    permission also records a model-visible error result for the blocked tool
    call; [message] defaults to ["Permission denied."] and is used as that
    denial text. [via] defaults to [`Reviewer] and is recorded as audit
    provenance on denial resolutions. Allowing once or for the session may let
    planning claim the tool immediately.

    Returns {!Error.Permission_not_pending} if [id] is not pending. Raises
    [Invalid_argument] if [via] is [`Unattended] and [answer] allows:
    unattended resolution can only deny. *)

val answer_host_tool :
  Config.t ->
  ?error:bool ->
  Waiting.host_tool ->
  text:string ->
  session ->
  (Step.t, Error.t) result
(** [answer_host_tool config ?error waiting ~text session] records [text] as
    the model-visible result for [waiting] and advances to the next external
    boundary.

    Empty [text] records an empty tool result. [error] defaults to [false];
    when [true], the result is marked as a tool error. The tool-result event
    is part of {!Step.events}. Returns {!Error.Tool_call_not_pending} if the
    saved session no longer has the matching pending host-tool call. *)

val answer_host_tool_result :
  Config.t ->
  Waiting.host_tool ->
  Spice_llm.Tool.Result.t ->
  session ->
  (Step.t, Error.t) result
(** [answer_host_tool_result config waiting result session] records [result]
    for [waiting] and advances to the next external boundary.

    [result] must answer the same call id and tool name as [waiting]. Returns
    {!Error.Tool_result_mismatch} if it does not, and
    {!Error.Tool_call_not_pending} if the saved session no longer has the
    matching pending host-tool call. *)
