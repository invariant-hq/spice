(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The session interpreter core.

    Internal to {!Spice_host}. This is the bottom of the session-runtime chain
    [compaction_run → session → session_loop → runner → live]: it owns the
    interpreter machinery ({!type:hooks}, the error flatteners, the save/effect
    loop) and speaks the protocol vocabulary — a {!Spice_protocol.Command.t} in,
    a saved document beside a {!Spice_protocol.Outcome.t} out,
    {!Spice_protocol.Event.t} on the observer, {!Spice_protocol.Error.t} on
    failure.

    {!Session} re-exposes {!type:hooks} and its combinators abstractly to
    library users and adds the standalone workflows; {!Runner} holds the
    injected parts and calls {!execute}. {!execute} is the interpreter's sole
    ingress: there is no second "advance the session" verb.

    The interpreter's contract — the invariants a maintainer must preserve —
    lives at {!execute}: planned events are saved before every model request and
    before every executable tool claim; an executable tool runs at most once per
    saved claim; the pressure guard latches one summary per over-limit episode
    and the overflow guard allows one recovery per model failure; a fired
    cancellation finishes the active turn as interrupted. *)

(** {1:types Types} *)

type request_preparation = {
  request : Spice_llm.Request.t;
      (** The request to send, after any notice prelude was appended. *)
  commit : unit -> unit;  (** Runs once the response is accepted. *)
  rollback : unit -> unit;
      (** Runs when preparation or the provider call fails before a response is
          accepted. *)
}
(** A prepared ordinary model request. Notice injection produces one of these:
    [commit] consumes the drained batch, [rollback] returns it. *)

type hooks = {
  prepare_request :
    Spice_llm.Request.t -> (request_preparation, Spice_protocol.Error.t) result;
      (** Runs immediately before each ordinary model request. Summary requests
          built by compaction do not run it. Notice injection installs itself
          here. *)
  after_save :
    Spice_session_store.Document.t -> Spice_session.Event.t list -> unit;
      (** Runs after each saved event suffix — both the interpreter's own saves
          and a compaction install — with the saved document and the applied
          events. *)
  around_tool :
    observe:(Spice_protocol.Event.t -> unit) ->
    Spice_session_store.Document.t ->
    Spice_session.Tool_claim.Started.t ->
    Spice_tool.Output.t Spice_tool.Result.t ->
    unit;
      (** Applied to [~observe (document, claim)] after the claim is saved and
          before the executable effect runs, yielding the finish callback run on
          the tool result after the effect and before the durable tool-finished
          event is saved. Mutation evidence records through it. [observe] is
          passed by {!execute} at fire time — the current {!field:observe}, not
          a value captured when the hook was composed — so a recorder emits to
          the runner's final observer regardless of hook composition order. *)
  observe : Spice_protocol.Event.t -> unit;
      (** The event sink: durable events after their session events are saved,
          live-only progress deltas as they occur. *)
  terminal :
    observe:(Spice_protocol.Event.t -> unit) ->
    Spice_session_store.Document.t * Spice_protocol.Outcome.t ->
    unit;
      (** Runs once when a command settles at a terminal outcome (blocked or
          finished), with the same [(document, outcome)] pair {!execute}
          returns. It does not run on an error settle. [observe] is the current
          {!field:observe}, passed by {!execute} at fire time for the same
          late-binding reason as {!field:around_tool}. *)
  cancelled : unit -> bool;
      (** Sampled between effects; [true] finishes the active turn as
          interrupted instead of performing the next planned effect. *)
}
(** The interpreter's optional side effects, threaded through {!execute}. Not
    session state. The record is transparent here so the interpreter reads its
    fields; {!Session} narrows it to an abstract type for library users, who
    build values only through {!no_hooks} and the combinators below. *)

(** {1:hooks Hooks} *)

val no_hooks : hooks
(** [no_hooks] installs nothing: every field is inert. *)

val no_observe : Spice_protocol.Event.t -> unit
(** [no_observe] discards an event. It is the default {!field:observe}. *)

val no_after_save :
  Spice_session_store.Document.t -> Spice_session.Event.t list -> unit
(** [no_after_save] discards a save suffix. It is the default
    {!field:after_save}. *)

val not_cancelled : unit -> bool
(** [not_cancelled] is always [false]. It is the default {!field:cancelled} and
    the signal manual compaction runs under. *)

val with_prepare_request :
  (Spice_llm.Request.t -> (request_preparation, Spice_protocol.Error.t) result) ->
  hooks ->
  hooks
(** [with_prepare_request prepare hooks] replaces {!field:prepare_request}. *)

val with_after_save :
  (Spice_session_store.Document.t -> Spice_session.Event.t list -> unit) ->
  hooks ->
  hooks
(** [with_after_save after_save hooks] replaces {!field:after_save}. *)

val after_save :
  hooks -> Spice_session_store.Document.t -> Spice_session.Event.t list -> unit
(** [after_save hooks document events] runs the installed {!field:after_save}.
    It is the eliminator a tap chains before recording its own post-save state.
*)

val with_around_tool :
  (observe:(Spice_protocol.Event.t -> unit) ->
  Spice_session_store.Document.t ->
  Spice_session.Tool_claim.Started.t ->
  (Spice_tool.Output.t Spice_tool.Result.t -> unit) ->
  Spice_tool.Output.t Spice_tool.Result.t ->
  unit) ->
  hooks ->
  hooks
(** [with_around_tool around hooks] adds a layer to {!field:around_tool}. Unlike
    the replacing combinators, this self-chains: [around] receives the finish
    callback already installed and returns the new one, so successive layers
    nest. [around] takes the loop-supplied [~observe] (see
    {!field:around_tool}), so it emits to the runner's live observer without
    capturing one at composition time. *)

val with_observe : (Spice_protocol.Event.t -> unit) -> hooks -> hooks
(** [with_observe observe hooks] replaces {!field:observe}. *)

val observe : hooks -> Spice_protocol.Event.t -> unit
(** [observe hooks event] runs the installed {!field:observe}. It is the
    eliminator a tap chains to forward events after its own delivery. *)

val with_terminal_observed :
  (observe:(Spice_protocol.Event.t -> unit) ->
  Spice_session_store.Document.t * Spice_protocol.Outcome.t ->
  unit) ->
  hooks ->
  hooks
(** [with_terminal_observed terminal hooks] adds a callback to {!field:terminal},
    run once when execution reaches a terminal outcome. It self-chains: the prior
    terminal callback runs before [terminal]. [terminal] receives the
    loop-supplied [~observe] (see {!field:terminal}), so a callback that emits
    events on a terminal outcome — the end-of-run mutation checkpoint — emits to
    the runner's live observer without capturing one at composition time. *)

val with_cancelled : (unit -> bool) -> hooks -> hooks
(** [with_cancelled cancelled hooks] replaces {!field:cancelled}. *)

val with_notices :
  ?before_request:(unit -> unit) -> Notice_queue.t -> hooks -> hooks
(** [with_notices ?before_request queue hooks] installs notice injection through
    {!with_prepare_request}: it drains [queue] into a {!request_preparation}
    whose [commit] consumes the batch after the response is accepted and whose
    [rollback] returns it on failure, emitting
    {!Spice_protocol.Event.Notices_injected} when a batch is non-empty.
    [before_request] runs immediately before the batch is taken. *)

(** {1:errors Error flattening}

    Lower-layer errors are regrouped into the protocol error's caller-recovery
    classes; invariant violations a host cannot repair become
    {!Spice_protocol.Error.Internal}. *)

val of_store :
  ?id:Spice_session.Id.t ->
  Spice_session_store.Error.t ->
  Spice_protocol.Error.t
(** [of_store ?id error] maps a store error into the protocol error. [id]
    supplies the session id for a wrapped session-domain error, which has none
    of its own. *)

val of_compaction :
  id:Spice_session.Id.t -> Compaction_run.error -> Spice_protocol.Error.t
(** [of_compaction ~id error] maps a {!Compaction_run.error} into the protocol
    error, with [id] in scope for any wrapped store error. *)

(** {1:preconditions Preconditions and store} *)

val check_active_document :
  Spice_session.t -> (unit, Spice_protocol.Error.t) result
(** [check_active_document session] is [Ok ()] iff [session] is neither archived
    nor deleted. *)

val require_no_active_turn :
  Spice_session.t -> (unit, Spice_protocol.Error.t) result
(** [require_no_active_turn session] is [Ok ()] iff [session] has no active
    turn, and {!Spice_protocol.Error.Active_turn_exists} otherwise. *)

val raw_save :
  Spice_session_store.t ->
  Spice_session_store.Document.t ->
  Spice_session.Event.t list ->
  (Spice_session_store.Document.t, Spice_session_store.Error.t) result
(** [raw_save store document events] appends [events] to [document] (a no-op on
    the empty list) without the interpreter's error mapping. It is the store
    seam {!Compaction_run.compact_with} writes the install through, shared by
    the idle and mid-turn compaction paths. *)

(** {1:execute Execution} *)

type plan_resolver =
  decision:Spice_protocol.Plan.Decision.t ->
  Spice_protocol.Plan.Proposal.t ->
  (string, Spice_protocol.Error.t) result
(** The type for the host-side plan resolution the {!Spice_protocol.Command.Resolve_plan}
    executor calls. It applies [decision] to a parked proposal — the durable
    [Proposed → Approved/Rejected] transition and the model-visible answer
    wording — and returns the wording to answer the blocked call with, or the
    execution error a resolution failure raises (a superseded plan becomes
    {!Spice_protocol.Error.Internal}). It is injected rather than called
    directly so the loop keeps no filesystem dependency, mirroring [host_tool]. *)

val execute :
  store:Spice_session_store.t ->
  client:Spice_llm.Client.t ->
  host_tool:Handler.t ->
  resolve_plan:plan_resolver ->
  run:Spice_session.Run.Config.t ->
  ?compaction:Compactor.Policy.t ->
  hooks:hooks ->
  Spice_session_store.Document.t ->
  Spice_protocol.Command.t ->
  ( Spice_session_store.Document.t * Spice_protocol.Outcome.t,
    Spice_protocol.Error.t )
  result
(** [execute ~store ~client ~host_tool ~run ?compaction ~hooks document command]
    interprets [command] against [document] until the session blocks or
    finishes, returning the latest saved document beside its
    {!Spice_protocol.Outcome.t}.

    Save-before-effect: each planned event suffix is appended before the model
    request or executable tool it precedes is interpreted. An executable tool
    runs at most once per saved claim; a host-tool boundary is answered inline
    by [host_tool] or, if it declines, returned as
    {!Spice_protocol.Outcome.Waiting} with the classified call. A
    {!Spice_protocol.Command.Answer} re-derives the pending host-tool boundary
    from the session and matches [(turn, call id)], reporting a mismatch as
    {!Spice_protocol.Error.Tool_call_not_pending}.

    When [compaction] is present, an over-limit ordinary request triggers one
    pressure compaction per over-limit episode (the guard latches until a
    boundary projects under the limit), and a context-overflow model failure
    triggers one overflow-recovery compaction (the guard resets on each accepted
    response). [hooks] observe and steer the run; {!field:terminal} fires once
    on a terminal Ok settle. *)
