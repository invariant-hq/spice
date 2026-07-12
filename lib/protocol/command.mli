(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The session execution ingress.

    A command is a request a client makes of a session: start a turn, resume a
    blocked one, resolve a pending permission or host-tool boundary, record a
    recovered tool result, or interrupt. The engine checks session-dependent
    preconditions at execute time and reports violations as {!Error.t}
    ({!Error.Tool_call_not_pending}, {!Error.Invalid_answer},
    {!Error.Active_turn_exists}, …). {!Start.t} is abstract for a different
    reason: model, mode, and tool catalogs are not client input at all; the
    configured runner owns them.

    {!Command.t} in and {!Event.t} out is the narrow waist a session speaks. *)

module Start : sig
  (** Client-owned data for starting a turn. The bound runner supplies the
      effective model, mode, and host-tool catalog recorded on the accepted
      turn. *)

  type t
  (** The type for a turn-start request. *)

  val make :
    id:Spice_session.Turn.Id.t ->
    input:Spice_session.Turn.Input.t ->
    ?options:Spice_llm.Request.Options.t ->
    ?origin:string ->
    ?max_steps:int ->
    unit ->
    t
  (** [make ~id ~input ?options ?origin ?max_steps ()] requests a new turn.
      [options] and [origin] have the same meaning as their
      {!Spice_session.Turn.make} counterparts. [max_steps] requests a positive
      per-turn limit; the session runner may clamp it to its safety cap. Raises
      [Invalid_argument] when a present [origin] is empty or [max_steps] is not
      positive. *)

  val id : t -> Spice_session.Turn.Id.t
  (** [id t] is the requested turn id. *)

  val input : t -> Spice_session.Turn.Input.t
  (** [input t] is the requested durable user input. *)

  val options : t -> Spice_llm.Request.Options.t option
  (** [options t] is the request-specific model option set, if supplied. *)

  val origin : t -> string option
  (** [origin t] is the optional turn origin tag. *)

  val max_steps : t -> int option
  (** [max_steps t] is the optional per-turn step limit. *)
end

type t =
  | Start of Start.t
      (** Ask the bound runner to append and advance a turn. *)
  | Resume  (** Advance the active turn from its saved boundary. *)
  | Reply of {
      permission : Spice_session.Permission.Id.t;
      answer : Spice_session.Permission.Resolved.answer;
      via : Spice_session.Permission.Resolved.via option;
      message : string option;
    }
      (** Resolve a pending permission review. [message] is the model-visible
          denial text (default ["Permission denied."]); [via] defaults to
          [`Reviewer] and must not be [`Unattended] when [answer] allows. *)
  | Answer of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      answer : string;
    }
      (** Answer a blocked host-tool call, named by its turn and model call id,
          with the user's raw [answer]. [call_id] is the plain
          {!Spice_llm.Tool.Call.id}; the engine re-derives the pending host-tool
          boundary from the session, matches [turn] and [call_id], and applies
          that call's canonical answer rendering. A mismatch is
          {!Error.Tool_call_not_pending}; an empty answer or a call without a
          user-answer contract is {!Error.Invalid_answer}. A client obtains
          [(turn, call_id)] from a prior {!Outcome.Waiting}. *)
  | Resolve_plan of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      decision : Plan.Decision.t;
    }
      (** Resolve a blocked [propose_plan] host-tool call, named by its turn and
          model call id. The engine re-derives the pending host-tool boundary
          exactly as {!Answer} does (a mismatch is
          {!Error.Tool_call_not_pending}), applies [decision] to the parked
          proposal — the durable [Proposed → Approved/Rejected] transition and
          the model-visible answer wording, host-side — and answers the blocked
          call with that wording. A proposal that can no longer be resolved (a
          superseded plan) is a {!Error.Internal}. This replaces the client-side
          plan resolution the old TUI performs before submitting an {!Answer}: a
          remote client no longer links artifact storage or computes the answer
          text. *)
  | Finish_tool of
      Spice_session.Tool_claim.Id.t * Spice_tool.Output.t Spice_tool.Result.t
      (** Record a result for a pending unfinished tool claim — the recovery
          path for a host that crashed after claiming a tool.

          {b Note.} The result retains typed evidence ({!Spice_tool.Output.t});
          a wire projection drops it to serializable output plus
          {!Spice_mutation} facts. *)
  | Interrupt of { reason : string option }
      (** Finish the active turn as interrupted by cancellation. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)
