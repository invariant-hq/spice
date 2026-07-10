(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The subagent run registry.

    The registry owns every child run of one session tree: it mints the child
    session, records the {!Spice_protocol.Subagent_run} ledger in {!Artifacts},
    runs the child as its own {!Live} attachment, transitions the ledger when
    the child settles, and fans identity-tagged progress out to subscribers
    (doc/plans/subagent-tui.md §8.3).

    The registry is the live projection of the run tree; the artifact ledger
    and child sessions are the durable record. A lifecycle operation on a child
    not launched by this process hydrates that durable record on demand. Live
    attachments remain scoped to the switch passed to {!create}.

    Spawns are detached from the parent turn: {!spawn} returns once the child is
    launched, and the parent model can continue or explicitly call {!wait}. A
    CLI process still owns the child fibers, so callers that are about to tear
    down the registry must call {!drain} to let unsettled children persist their
    terminal or blocked ledger state first. *)

type t
(** The type for a session tree's run registry. *)

(** The type for {!wait}'s outcome. Four cases are settlements the spawning
    handler formats into the model-visible tool result — the ledger transition
    is already recorded and published when [wait] returns. {!Wait_interrupted}
    is the fifth, non-settlement case: the wait bailed out and the run is still
    going. *)
type outcome =
  | Summary of string
      (** The child finished (completed or step-limit) with this final text — or
          a placeholder when it produced no visible text. *)
  | Blocked_on of { blocker : string }
      (** The child parked on a waiting boundary; [blocker] is the
          human-readable cause. The ledger records
          {!Spice_protocol.Subagent_run.Status.Blocked}. *)
  | Interrupted of { reason : string option; cancelled : bool }
      (** The child turn was interrupted. The ledger records
          {!Spice_protocol.Subagent_run.Status.Cancelled}. *)
  | Failed_with of string
      (** The child turn failed, or its drain errored. The ledger records
          {!Spice_protocol.Subagent_run.Status.Failed}. *)
  | Wait_interrupted
      (** Not a settlement: the {!wait} itself was interrupted while the run was
          still going. The paired record is the latest non-terminal state; the
          run keeps running and can be waited on again. *)

(** The type for registry events. Delivered synchronously on the producing
    child's drain fiber, per-run ordered; cross-run order is unspecified. A
    subscriber that raises is isolated to that delivery. *)
type event =
  | Started of Spice_protocol.Subagent_run.t
      (** The run was minted and its Start submitted. *)
  | Progress of Spice_protocol.Subagent_progress.t
      (** One child event, tagged with the run identity. *)
  | Blocked of {
      run : Spice_protocol.Subagent_run.t;
      waiting : Spice_session.Waiting.t;
    }
      (** The child parked on a waiting boundary other than an ask — the
          escalation channel. [waiting] is the parked boundary: a surface
          renders the permission prompt from it and answers with {!answer}. *)
  | Asked of { run : Spice_protocol.Subagent_run.t; message : string }
      (** The child parked on a [message_parent] ask; emitted immediately before
          the paired {!Settled}. [message] is the pending question {!asked} then
          returns. *)
  | Resumed of Spice_protocol.Subagent_run.t
      (** A settled run was resumed by a message or an answer; the ledger is
          back to Running and a new settlement will follow. *)
  | Settled of Spice_protocol.Subagent_run.t
      (** The run reached a caller-facing settlement (terminal status, or
          {!Spice_protocol.Subagent_run.Status.Blocked} under today's
          settle-on-block policy). *)

type child = {
  runner :
    Spice_session.Id.t -> notices:Notice_queue.t -> (Runner.t, string) result;
      (** [runner child ~notices] builds the child's interpreter once the child
          session id is minted — {!Run}'s child-runtime assembly: parent tools,
          client, and context filtered by the role contract. [notices] is the
          registry-owned per-run queue the runner must drain at its request
          boundaries ({!Session.with_notices}) — parent messages ride it. *)
  prompt : string;  (** The child turn's user-text input. *)
  title : string;  (** The child session title. *)
  cwd : Spice_path.Abs.t;  (** The child session working directory. *)
}
(** The type for the spawn-time child specification. The registry owns ids,
    times, ledger writes, and the Live attachment; the caller owns prompt
    assembly and runner construction. *)

type resume_runner =
  Spice_protocol.Subagent_run.t ->
  notices:Notice_queue.t ->
  (Runner.t, string) result
(** The type for rebuilding a runner when a persisted blocked or terminal child
    resumes in a later host process. The caller derives the runner from the
    current turn's model, credential, mode, and the recorded child role; the
    registry owns the child document and notice queue. *)

val create :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  store:Spice_session_store.t ->
  parent:Spice_session.Id.t ->
  max_concurrent:int ->
  max_depth:int ->
  max_exchanges:int ->
  t
(** [create ~sw ~stdenv ~store ~parent ~max_concurrent ~max_depth
    ~max_exchanges] is [parent]'s live session-tree registry. Child drain fibers
    run on [sw]; ledger artifacts live under [store]'s root. A child absent from
    the live registry is located among [parent]'s durable descendants and loaded
    when first addressed. Registry lifetime is [sw]'s.

    [max_exchanges] caps parent<->child message exchanges per run — model-origin
    sends over the cap fail, asks over the cap park with the cap named as
    blocker, user-origin sends are exempt. [max_concurrent] caps running
    episodes over the whole tree — it is also the provider fan-out bound, since
    every running child holds a client slot. Spawning or resuming a child over
    the bound fails before its ledger transitions to running. [max_depth] caps
    nesting; root children are depth [1]. A spawn over the depth cap fails
    before any minting. *)

val spawn :
  t ->
  parent:Spice_session.Id.t ->
  parent_turn:Spice_session.Turn.Id.t ->
  parent_call_id:string ->
  spawn:Spice_protocol.Subagent.Spawn.t ->
  depth:int ->
  child ->
  (Spice_session.Id.t, string) result
(** [spawn t ~parent ~parent_turn ~parent_call_id ~spawn ~depth child] mints the
    child session and queued run ledger entry, transitions it running, attaches
    the child as a {!Live}, and submits its start turn — fire-and-forget.
    Returns the child session id: the run key everywhere. Errors are
    model-visible strings (cap violations before any minting, then storage,
    ledger, or runner-assembly failures). A failed spawn leaves no registered
    run, child session, or ledger record; a rollback failure is included in the
    returned error. *)

val wait :
  ?cancelled:(unit -> bool) ->
  t ->
  caller:Spice_session.Id.t ->
  Spice_session.Id.t ->
  (Spice_protocol.Subagent_run.t * outcome, string) result
(** [wait ?cancelled t ~caller run] loads [run] from durable storage when necessary,
    blocks the calling fiber until it settles, and
    returns the settled ledger record with its caller-facing outcome. The ledger
    transition and {!Settled} publication happen before [wait] returns. Errors
    when [run] is not a strict descendant of [caller]. This rejects self- and
    ancestor-waits before blocking, so recursive runs cannot form a wait cycle.

    [cancelled] is sampled while blocked (it defaults to never cancelled); when
    it flips, [wait] returns {!Wait_interrupted} with the latest non-terminal
    record instead of waiting out the block — the turn's interrupt is not
    deferred behind a running child.

    Blocking is cooperative: child drains progress while the caller waits. A
    settlement is final for its episode; a {!message}- or {!answer}-resumed run
    settles again and [wait] observes the new settlement. The durable fallback
    searches [parent]'s whole tree, so recursive descendants remain addressable
    after a process restart without exposing another root's runs. *)

val drain : ?cancelled:(unit -> bool) -> t -> unit
(** [drain ?cancelled t] waits for every run that is unsettled when [drain]
    starts. It is the process-teardown companion to detached spawning: child
    fibers live under the registry switch, so draining gives them a chance to
    write their completed, blocked, failed, or cancelled ledger state before the
    switch closes. Unknown-run errors are impossible for the captured registry
    entries and are ignored. *)

val cancel :
  t -> caller:Spice_session.Id.t -> Spice_session.Id.t -> (unit, string) result
(** [cancel t ~caller run] cancels descendant [run]: an unsettled run gets an interrupt on its
    attachment and settles as cancelled through the ordinary settlement path; a
    run parked on a waiting boundary is cancelled directly — a pure ledger
    transition plus release of the held attachment, published as {!Settled}.
    Errors when [run] is not a strict descendant of [caller], is not registered,
    or already settled terminally. *)

val message :
  runner:resume_runner ->
  origin:[ `Model | `User ] ->
  t ->
  caller:Spice_session.Id.t ->
  Spice_session.Id.t ->
  string ->
  ([ `Delivered | `Resumed ], string) result
(** [message ~runner ~origin t ~caller run text] delivers [text] to descendant
    [run], resolving to
    exactly one of:

    - [`Delivered] — [run] is unsettled, or parked on a non-ask boundary: [text]
      is published to the run's notice queue under a fresh per-message key and
      reaches the child immediately before its next model request. A child that
      settles without another request keeps the message queued; it drains into
      the run's next turn.
    - [`Resumed] — [run] had settled. Parked on a [message_parent] ask, the
      parked turn resumes with [text] as that call's result; terminal, a fresh
      attachment is rebuilt over the run's document and a new turn starts with
      [text] as user input. Either way the ledger transitions back to Running
      ({!Spice_protocol.Subagent_run.resume}), {!Resumed} is published, and the
      next settlement is observed by {!wait} anew.

    The choice is atomic: [message] performs no suspension between reading the
    run's settlement state and acting, so a message is never both delivered and
    resumed, and never dropped.

    [runner] rebuilds the child's interpreter only when a durable child without
    a live attachment must resume. [origin] is exchange-cap accounting:
    [`Model] counts against the per-run cap
    and errors once it is reached; [`User] — the drill-in composer — bypasses
    the exchange cap so a person can always steer or unpark a run. Resuming a
    settled child still errors when the running-child capacity is full. Errors
    also on an unknown run. *)

val asked : t -> Spice_session.Id.t -> string option
(** [asked t run] is the pending unanswered [message_parent] text when [run] is
    parked on an ask — the structured blocked cause whose summary is the
    ledger's blocker string. Cleared when a {!message} or {!answer} resumes it;
    [None] otherwise or for unknown runs. *)

val answer :
  runner:resume_runner ->
  t ->
  caller:Spice_session.Id.t ->
  Spice_session.Id.t ->
  Spice_protocol.Command.t ->
  (unit, string) result
(** [answer ~runner t ~caller run command] resumes a descendant run parked on a waiting boundary
    with the continuation [command] — a permission
    {!Spice_protocol.Command.Reply} or a host-tool
    {!Spice_protocol.Command.Answer} the surface built from the boundary it
    rendered. [runner] rebuilds a live attachment when [run] was hydrated from
    durable storage. The ledger transitions back to Running and {!Resumed} is
    published. Errors when [run] is not parked. *)

val subscribe : t -> (event -> unit) -> unit
(** [subscribe t handler] subscribes [handler] to [t]'s event feed for the
    registry's lifetime. See {!event} for delivery discipline. *)

val is_pending : t -> bool
(** [is_pending t] is [true] iff one of [t]'s child attachments has work queued
    or in progress. Runs parked on a waiting boundary are not pending. *)

val publish_notice :
  t ->
  Spice_session.Id.t ->
  Spice_protocol.Notice.t ->
  (unit, string) result
(** [publish_notice t child notice] queues [notice] for [child]'s next model
    request. It is the direct-parent delivery seam for recursive descendants:
    {!Run} formats a grandchild settlement and publishes it to the child that
    spawned that run. Errors when [child] is not recorded in the tree. *)

val list : t -> Spice_protocol.Subagent_run.t list
(** [list t] is every registered run's latest ledger record, in spawn order. *)
