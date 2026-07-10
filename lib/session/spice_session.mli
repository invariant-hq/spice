(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable sessions and pure replay state.

    [spice.session] defines the durable session value saved by the host and the
    semantic event language used to reconstruct a checked model-visible
    transcript. It does not define a store, scheduler, model client, executable
    tool runtime, or host session service.

    Construct sessions with {!create} or {!make}, inspect the reconstructed
    replay projection with {!state}, and use {!Run} for ordinary active-turn
    mutation. Low-level import, repair, and replay tests can append raw semantic
    facts through {!Log}.

    Metadata changes and lifecycle changes are session updates, not semantic
    events. They do not modify {!state}, {!events}, or the model-visible
    transcript. *)

module Id = Id
(** Session identifiers. *)

module Time = Time
(** Durable session timestamps. *)

module Revision = Revision
(** Optimistic-concurrency revision tokens. *)

module Metadata = Metadata
(** Durable session metadata. *)

module Turn = Turn
(** Accepted model/tool loop facts. *)

module Permission = Permission
(** Durable permission request and reply facts. *)

module Tool_claim = Tool_claim
(** Durable executable tool claims. *)

module Compaction = Compaction
(** Durable model-replay compactions. *)

module Waiting = Waiting
(** Derived execution waiting boundaries. *)

module Event = Event
(** Durable session events. *)

module State = State
(** Pure reconstructed session state. *)

module Anchor = Anchor
(** Stable, replay-valid rewind positions. *)

(** {1:errors Errors} *)

module Error : sig
  (** Session operation errors. *)

  type t =
    | State of State.Error.t
        (** Semantic event replay failed while constructing or appending to the
            session. *)
    | Archived  (** The operation requires a non-archived session. *)
    | Deleted  (** The operation requires a non-deleted session. *)
    | Active_turn of Turn.Id.t
        (** The operation requires no active unfinished turn. *)
    | Unknown_turn of Turn.Id.t
        (** An anchor named a turn that is not present in the session. *)
    | Turn_not_finished of Turn.Id.t
        (** An {!Anchor.After} anchor named a turn with no terminal outcome. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The returned string is suitable for display and logs. Callers that need
      stable control flow should inspect [e] directly. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. The output is not stable storage
      syntax. *)
end

(** {1:sessions Sessions} *)

type t
(** The type for durable saved Spice sessions.

    A session contains its id, metadata, semantic event log, and a validated
    {!State.t} projection of that log. The projection is derived from the events
    and is validated whenever a session is decoded, reconstructed, or appended.

    The host owns where and how sessions are saved, including store uniqueness,
    revision checks, and timestamp policy. *)

type session = t
(** Alias for the session type, used in nested signatures whose own [t] would
    otherwise shadow the outer session type. *)

val create :
  id:Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  unit ->
  t
(** [create ~id ?title ~cwd ~created_at ()] is a new active session with no
    semantic events.

    [created_at] is used for both metadata creation and update time.

    Raises [Invalid_argument] if [title] is empty. *)

val make :
  id:Id.t -> metadata:Metadata.t -> events:Event.t list -> (t, Error.t) result
(** [make ~id ~metadata ~events] is a session reconstructed from saved parts.

    Returns [Error (State e)] if [events] do not form a valid semantic session
    replay. Metadata is not replayed; an archived or deleted session can still
    be reconstructed if its semantic events are valid. *)

val id : t -> Id.t
(** [id t] is [t]'s session id. *)

val metadata : t -> Metadata.t
(** [metadata t] is [t]'s durable session metadata. *)

val events : t -> Event.t list
(** [events t] is [t]'s semantic event log in application order. *)

val state : t -> State.t
(** [state t] is [t]'s validated semantic replay projection. *)

(** Machine-readable metrics projected from durable session events. *)
module Metrics : sig
  (** Machine-readable session spend and activity metrics. *)

  type t = private {
    usage : Spice_llm.Usage.t;
        (** Lane-wise sum of provider-reported response usage. Responses without
            usage contribute {!Spice_llm.Usage.zero}. *)
    responses : int;  (** Number of completed provider responses. *)
    turns : int;  (** Number of terminal turn events. *)
    tool_calls : int;  (** Number of finished executable tool calls. *)
    tool_failures : int;
        (** Number of finished executable tool calls marked as errors. *)
    tool_rejections : int;
        (** Number of model tool calls answered with an error result without
            being executed. Denied permission replies are counted by
            [permission_denials], not here. *)
    tool_calls_by_name : (string * int) list;
        (** Finished executable tool-call counts by model-visible tool name,
            sorted by name. *)
    permission_denials : int;  (** Number of denied permission replies. *)
  }
  (** The type for cumulative session metrics. Counts are non-negative. *)

  val of_events : Event.t list -> t
  (** [of_events events] is the low-level cumulative metrics projection of an
      already-validated event log.

      Raises [Invalid_argument] if an integer lane overflows. *)

  val of_session : session -> t
  (** [of_session session] is the cumulative metrics projection of [session]'s
      validated event log.

      Raises [Invalid_argument] if an integer lane overflows. *)

  val empty : t
  (** [empty] is the zero metrics value. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same metrics. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats metrics for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps metrics to JSON objects. *)
end

val set_title : string option -> t -> t
(** [set_title title t] is [t] with title [title].

    This does not change [updated_at].

    Raises [Invalid_argument] if [title] is [Some ""]. *)

val touch : Time.t -> t -> t
(** [touch time t] is [t] with its saved metadata update time set to [time].

    Raises [Invalid_argument] if [time] is before the session creation time. *)

val archive : t -> (t, Error.t) result
(** [archive t] is [t] marked archived.

    Archiving an archived session is idempotent. Returns {!Error.Active_turn} if
    [t] has an active turn. Returns {!Error.Deleted} if [t] is deleted. This
    does not change [updated_at]. *)

val restore : t -> (t, Error.t) result
(** [restore t] is [t] marked active.

    Restoring an active session is idempotent. Returns {!Error.Deleted} if [t]
    is deleted. This does not require the session to be idle and does not change
    [updated_at]. *)

val delete : t -> (t, Error.t) result
(** [delete t] is [t] marked deleted.

    Deleting a deleted session is idempotent. Returns {!Error.Active_turn} if
    [t] has an active turn. Archived sessions may be deleted. This does not
    change [updated_at]. *)

val fork :
  id:Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  t ->
  (t, Error.t) result
(** [fork ~id ?title ~cwd ~created_at t] is a new active session with [t]'s
    current semantic events and fork lineage pointing to [t].

    The parent may be active or archived, but must not have an unfinished turn.
    Returns {!Error.Active_turn} if [t] has an active turn. Returns
    {!Error.Deleted} if [t] is deleted. Raises [Invalid_argument] if [title] is
    empty. The child metadata [created_at] and [updated_at] are both set to
    [created_at]. *)

(** {1:rewind Rewind} *)

val resolve_anchor : Anchor.t -> t -> (int, Error.t) result
(** [resolve_anchor anchor t] is the copied-event prefix length [anchor] names
    in [t]: the number of leading events a child keeps.

    The cut is the exact event index of the named boundary. {!Anchor.Before}
    cuts at the [Turn_started] event index, so idle system, developer, and user
    messages appended after the previous turn finished are {e kept} in the
    prefix; {!Anchor.After} cuts just past the [Turn_finished] event index.
    Adjacent turns' [Before]/[After] edges therefore differ by any idle messages
    between them: [after_turn (n - 1)] resolves to a shorter prefix than
    [before_turn n] whenever such messages sit between turn [n - 1] and turn
    [n]. [before_turn] of the first turn resolves to [0] — a valid empty-log
    prefix equivalent to a fresh {!create}.

    Returns {!Error.Unknown_turn} if the anchored turn is not in [t], and
    {!Error.Turn_not_finished} for an {!Anchor.After} anchor on a turn that has
    no terminal outcome. *)

val dropped_turns : Anchor.t -> t -> (Turn.Id.t list, Error.t) result
(** [dropped_turns anchor t] is the turns [anchor] drops, in start order: those
    whose [Turn_started] event index is at or after the resolved cut.

    This is one edge-uniform rule. For {!Anchor.Before} the cut is the turn's
    own [Turn_started] index, so the anchored turn and every later turn are
    dropped; for {!Anchor.After} the cut is just past the turn's [Turn_finished]
    index, so the anchored turn is kept and every later turn is dropped. Because
    {!State.turns} is in start order the result is always a suffix of it.

    Fails with the same errors as {!resolve_anchor}. The engine ledger revert
    and the TUI preview share this derivation rather than re-scanning. *)

val rewind :
  id:Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  Anchor.t ->
  t ->
  (t, Error.t) result
(** [rewind ~id ?title ~cwd ~created_at anchor t] is a new active session whose
    events are [t]'s prefix up to [anchor] and whose {!Metadata.Forked_from}
    lineage points at [t] with [copied_events] set to the resolved prefix
    length.

    Like {!fork}, [t] must be not-deleted and have no active unfinished turn;
    the guard is on the {e parent} [t], so a [Before] anchor that would itself
    drop an active turn is still refused while [t] has one. Returns
    {!Error.Active_turn} or {!Error.Deleted} accordingly, and the anchor
    resolution errors of {!resolve_anchor}. The prefix always ends on a turn
    boundary, so replay validity holds by construction. When [anchor] names
    [t]'s last boundary this is exactly {!fork}. Raises [Invalid_argument] if
    [title] is empty. *)

val jsont : t Jsont.t
(** [jsont] maps sessions to JSON values. Decoding validates semantic event
    replay, validates metadata and nested event payloads, rejects unknown
    members, and rejects unsupported versions. *)

module Log : sig
  (** Low-level semantic log mutation.

      Common host code should use {!Run}. These functions are for import,
      repair, migration, and replay tests that already own semantic event
      construction. *)

  val append : Event.t -> t -> (t, Error.t) result
  (** [append event t] is [t] with [event] appended.

      Returns {!Error.Archived} or {!Error.Deleted} if [t] is not active.
      Returns [Error (State e)] if applying [event] would violate semantic
      replay invariants. *)

  val append_all : Event.t list -> t -> (t, Error.t) result
  (** [append_all events t] appends [events] in list order.

      Returns the first error that would be returned by {!append}. On error no
      partial session is returned. *)
end

(** {1:running Running} *)

module Run : sig
  (** Pure run planning for active session turns.

      [Run] is the pure planner for the model/tool loop over a durable session.
      It validates and appends session events, builds model requests, dispatches
      decoded executable tool calls, applies permission policy, and reports the
      next external boundary. It does not call the model, run tools, save
      sessions, or own workspace state.

      Hosts call {!start}, {!resume}, or a continuation function, durably save
      {!Step.events} and {!Step.session}, interpret {!Step.next}, and feed the
      external result back with {!accept_response}, {!finish_tool},
      {!resolve_permission}, or {!answer_host_tool}.

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
      | Unknown_active_turn of Turn.Id.t
          (** The active turn id is not present in reconstructed state. *)
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
    (** [message e] is a human-readable diagnostic for [e]. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats [e] for diagnostics. *)
  end

  module Config : sig
    (** Immutable runtime inputs for deciding session steps. *)

    type t
    (** The type for checked executable tools, host-handled model-visible tools,
        permission policy, request prelude, and default step limit.

        A config carries no model client, scheduler, store, workspace, or
        mutable run state. *)

    val make :
      tools:Spice_tool.t list ->
      ?host_tools:Spice_llm.Tool.t list ->
      policy:Spice_permission.Policy.t ->
      ?prelude:Spice_llm.Request.Prelude.t ->
      ?max_steps:int ->
      ?denial_message:(Spice_permission.Policy.Denial.t -> string) ->
      unit ->
      t
    (** [make ~tools ?host_tools ~policy ?prelude ?max_steps ?denial_message ()]
        is a checked run config.

        [tools] are executable host capabilities. [host_tools] are model-visible
        tools whose calls block the run for product-owned host handling. A call
        is classified as host-handled by tool name before executable-tool
        dispatch.

        [prelude] defaults to {!Spice_llm.Request.Prelude.empty} and is used for
        every model request built from this config. It does not become session
        transcript state.

        [max_steps] defaults to [max_int] (effectively unbounded; interrupt is
        the safety valve) and is used when the active {!Turn.t} has no recorded
        limit.

        [denial_message] renders the model-visible tool error text for a tool
        call denied by policy without review. It defaults to a stable generic
        message. The function must be pure; its result becomes durable
        transcript state.

        Raises [Invalid_argument] if [tools] contains duplicate tool names, if
        an executable tool cannot be projected to a model-visible declaration,
        if a host-tool name is duplicated or also used by an executable tool, or
        if [max_steps] is not positive. *)

    val tools : t -> Spice_tool.t list
    (** [tools t] are [t]'s executable host capabilities. *)

    val host_tools : t -> Spice_llm.Tool.t list
    (** [host_tools t] are [t]'s model-visible host-handled tools. *)

    val policy : t -> Spice_permission.Policy.t
    (** [policy t] is [t]'s permission policy. *)

    val prelude : t -> Spice_llm.Request.Prelude.t
    (** [prelude t] is [t]'s model request prelude. *)

    val max_steps : t -> int
    (** [max_steps t] is [t]'s default positive model-response limit. *)

    val declarations : t -> Spice_llm.Tool.t list
    (** [declarations t] is the model-visible tool declaration list sent on
        every request built from [t]: executable tools rendered as LLM
        declarations, then host tools, in declaration order. *)
  end

  module Step : sig
    (** Planned session transition plus the next external boundary. *)

    type t
    (** The type for a checked session transition.

        [events t] is the exact event suffix applied to the input session, and
        [session t] is the validated session after that suffix. Hosts should
        save both before interpreting [next t]. Some steps append no events;
        callers still receive the session that was used to compute the boundary.
    *)

    (** The type for external boundaries after a planned transition. *)
    type next =
      | Request_model of Spice_llm.Request.t
          (** The active transcript is ready for the model.

              The host should save {!events}, call the model with the request,
              then continue with {!Run.accept_response}. *)
      | Run_tool of { claim : Tool_claim.Started.t; call : Spice_tool.Call.t }
          (** An executable tool call is decoded, permitted, and claimed.

              [claim] has a deterministic id derived from the active turn and
              model tool-call id. The host should save {!events}, run [call] at
              most once, then continue with {!Run.finish_tool}. *)
      | Waiting of Waiting.t
          (** The active turn is waiting for host or user input. Planning has
              not performed the waiting effect. *)
      | Finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
          (** The active turn reached a terminal outcome.

              [Completed] comes from a model response without tool calls.
              [Step_limit] is produced when the active turn has reached its
              model-response limit. [Interrupted] is produced by
              {!Run.interrupt}. *)

    val events : t -> Event.t list
    (** [events t] are the durable events appended by [t]. *)

    val session : t -> session
    (** [session t] is the validated session after {!events} [t]. *)

    val next : t -> next
    (** [next t] is the next external boundary after saving {!events} [t]. *)

    val pp_next : Format.formatter -> next -> unit
    (** [pp_next ppf next] formats [next] for diagnostics. *)
  end

  module Phase : sig
    (** Read-time execution phase of a saved session. *)

    type t =
      | Idle
      | Waiting of Waiting.t
      | Active  (** The type for coarse session execution phases. *)

    val to_string : t -> string
    (** [to_string t] is ["idle"], ["waiting"], or ["active"]. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics. *)
  end

  val phase : session -> Phase.t
  (** [phase session] is [session]'s read-time execution phase.

      Host-handled calls are classified from the active turn's recorded
      {!Turn.host_tools}, so this projection is parameter-free and historically
      stable. *)

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

      Host-tool names are stamped from [config]. [options] defaults to
      {!Spice_llm.Request.Options.default}. [max_steps], when absent, is
      inherited from [config] during planning. [mode] and [origin], when
      present, are durable host metadata interpreted outside replay.

      The returned step includes the turn-started event and any immediately
      planned events, such as a permission request or tool claim. Returns
      {!Error.State} if the turn cannot be appended, for example because
      [session] already has an active turn. *)

  val resume : Config.t -> session -> (Step.t, Error.t) result
  (** [resume config session] advances [session]'s active turn to the next
      external boundary.

      Existing waiting states are reported unchanged. A ready transcript becomes
      {!Step.Request_model}, unless the model-response limit is reached. A
      pending executable tool call is decoded, permission-checked, and either
      claimed, blocked for review, denied with a model-visible error result, or
      answered with a dispatch error result.

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
      unrun executable claim is finished with that result; a settled host-tool
      call or a not-yet-claimed call gets a direct tool result. This is the same
      error-result shape a normally interrupted tool records.

      Returns {!Error.No_active_turn} if [session] has no active turn. Raises
      [Invalid_argument] if [reason] is present and empty. *)

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
end
