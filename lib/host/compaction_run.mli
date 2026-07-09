(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The compaction engine, shared by manual and automatic compaction.

    Internal to {!Spice_host}. This module summarizes a session's request-ready
    replay transcript, installs the durable {!Spice_session.Compaction}, and
    returns the saved {!Compactor.result}. It is the single summarizer behind
    two callers: {!Session.compact} (idle, user-requested) and {!Session_loop}'s
    automatic pressure and overflow recovery (mid-turn). It owns no store, model
    client, or hooks — every effect arrives as a callback, so both callers reuse
    one implementation.

    Progress is emitted as {!Spice_protocol.Event.Compaction_progress} deltas
    and the terminal {!Spice_protocol.Event.Compaction}; the wrap around one
    attempt guarantees each {!Spice_protocol.Event.Started} is paired with
    exactly one terminal fact (install, {!Spice_protocol.Event.Skipped}, or
    {!Spice_protocol.Event.Failed}). *)

(** {1:errors Errors} *)

(** The type for a compaction failure, grouped by caller recovery class.

    Callers map it back into {!Spice_protocol.Error.t} with
    {!Session_loop.of_compaction}; this type keeps the distinctions that mapping
    needs. *)
type error =
  | Nothing_to_summarize
      (** No transcript prefix was eligible: nothing was summarized and nothing
          installed. Reported as a skip, not a hard failure. *)
  | No_compaction_model
      (** Neither the policy nor a prior turn supplied a summary model. *)
  | Empty_compaction_summary  (** The summary model returned only empty text. *)
  | Transcript_not_ready of Spice_llm.Transcript.Error.t
      (** The replay transcript was not request-ready (unresolved tool calls or
          waiting). *)
  | Provider of Spice_llm.Error.t
      (** The summary model call failed, including after the bounded
          overflow-retry loop is exhausted. *)
  | Store of Spice_session_store.Error.t
      (** Saving the installed compaction failed. *)
  | Internal of string  (** A lower-layer invariant was violated. *)

(** {1:overflow Overflow classification} *)

val is_context_overflow : Spice_llm.Error.t -> bool
(** [is_context_overflow error] is [true] iff [error] is a provider
    context-overflow. {!Session_loop} reads it to decide whether a failed
    ordinary model request is eligible for one overflow-recovery compaction. *)

(** {1:run The run} *)

val compact_with :
  save:
    (Spice_session_store.Document.t ->
    Spice_session.Event.t list ->
    (Spice_session_store.Document.t, Spice_session_store.Error.t) result) ->
  model:
    (cancelled:(unit -> bool) ->
    Spice_llm.Request.t ->
    (Spice_llm.Response.t, Spice_llm.Error.t) result) ->
  policy:Compactor.Policy.t ->
  observe:(Spice_protocol.Event.t -> unit) ->
  after_save:
    (Spice_session_store.Document.t -> Spice_session.Event.t list -> unit) ->
  cancelled:(unit -> bool) ->
  ?request:Spice_llm.Request.t ->
  Spice_session_store.Document.t ->
  reason:Spice_session.Compaction.Reason.t ->
  (Compactor.result, error) result
(** [compact_with ~save ~model ~policy ~observe ~after_save ~cancelled ?request
     document ~reason] summarizes [document]'s replay under [policy], installs
    the durable compaction, and returns the saved {!Compactor.result}.

    The effect seams are callbacks so both the idle and mid-turn callers inject
    their own store and client:
    - [save] persists an event suffix and returns the new document; it is the
      raw store append both callers share ({!Session_loop.raw_save}), so the
      install reaches the durable log without the interpreter's own error
      mapping.
    - [model] runs one summary request, sampling [cancelled].
    - [observe] receives the progress and terminal
      {!Spice_protocol.Event.Compaction_progress}/{!Spice_protocol.Event.Compaction}
      deltas.
    - [after_save] runs after the compaction event is saved, before
      {!Spice_protocol.Event.Compaction} is emitted.
    - [cancelled] is sampled by [model].

    [request], when given, is the pending ordinary request; it widens the
    projected-size the {!Spice_protocol.Event.Started} delta reports so it
    matches the number the trigger compared. [reason] is recorded on the durable
    compaction. Overflowing summary requests drop the oldest input and retry a
    bounded number of times before failing with {!Provider}. *)
