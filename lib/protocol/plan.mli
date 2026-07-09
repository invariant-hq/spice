(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Plan artifacts and the plan-approval boundary.

    A plan is host product state associated with a session turn. It is not
    {!Spice_session} replay state: the transcript records the messages and
    host-tool results, while this value records the approval boundary Plan mode
    imposes.

    A model proposes a plan through the {!Call.HOST_TOOL} surface ({!tool},
    {!decode}); the host saves it {!Status.Proposed} and the turn blocks. A user
    decision drives it through the transitions {!approve}, {!reject}, and
    {!supersede}. Construction and transitions are pure and report invariant
    failures as diagnostic strings. *)

module Id : sig
  (** Non-empty stable plan identifiers. *)

  type t
  (** The type for plan identifiers. The string form is the JSON value. *)

  val of_string : string -> (t, string) result
  (** [of_string s] is [s] as a plan id. Errors when [s] is empty. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representation. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps plan ids to JSON strings, funneling through {!of_string}. *)
end

module Source : sig
  (** Plan provenance in the parent session transcript. *)

  type t = private {
    session : Spice_session.Id.t;
    turn : Spice_session.Turn.Id.t;
    tool_call_id : string option;
  }
  (** The type for the session/turn location that produced a plan.

      [tool_call_id] is present when the plan came from a host-handled tool call
      and absent for host-created plans. *)

  val make :
    session:Spice_session.Id.t ->
    turn:Spice_session.Turn.Id.t ->
    ?tool_call_id:string ->
    unit ->
    (t, string) result
  (** [make ~session ~turn ?tool_call_id ()] is plan provenance. Errors when
      [tool_call_id] is present and empty. *)

  val session : t -> Spice_session.Id.t
  (** [session t] is the source session id. *)

  val turn : t -> Spice_session.Turn.Id.t
  (** [turn t] is the source turn id. *)

  val tool_call_id : t -> string option
  (** [tool_call_id t] is the source tool call id, if any. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same source. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps plan sources to JSON objects, funneling through {!make}. *)
end

module Status : sig
  (** Plan lifecycle status.

      {!Proposed} is the initial state. {!Approved} and {!Rejected} are terminal
      decisions for the current plan; {!Superseded} links this plan to a
      replacement. The transitions on {!type:Plan.t} enforce which changes are
      accepted. *)

  type t = private
    | Proposed
    | Approved of { approved_at : Spice_session.Time.t }
    | Rejected of { rejected_at : Spice_session.Time.t; reason : string option }
    | Superseded of { superseded_at : Spice_session.Time.t; by : Id.t }

  val proposed : t
  (** [proposed] is a plan awaiting a decision. *)

  val approved : approved_at:Spice_session.Time.t -> t
  (** [approved ~approved_at] is an approved status. *)

  val rejected :
    rejected_at:Spice_session.Time.t ->
    ?reason:string ->
    unit ->
    (t, string) result
  (** [rejected ~rejected_at ?reason ()] is a rejected status. Errors when
      [reason] is present and empty. *)

  val superseded : superseded_at:Spice_session.Time.t -> by:Id.t -> t
  (** [superseded ~superseded_at ~by] is a superseded status. *)

  val is_proposed : t -> bool
  (** [is_proposed t] is [true] iff [t] is {!Proposed}. *)

  val is_approved : t -> bool
  (** [is_approved t] is [true] iff [t] is {!Approved}. *)

  val is_rejected : t -> bool
  (** [is_rejected t] is [true] iff [t] is {!Rejected}. *)

  val is_superseded : t -> bool
  (** [is_superseded t] is [true] iff [t] is {!Superseded}. *)

  val transition_time : t -> Spice_session.Time.t option
  (** [transition_time t] is the time of [t]'s non-proposed transition. *)

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
(** The type for a plan.

    Invariants: [title] is absent or non-empty; [body] is non-empty markdown;
    non-proposed lifecycle times are at or after {!created_at}; a plan cannot
    supersede itself. *)

val propose :
  id:Id.t ->
  source:Source.t ->
  ?title:string ->
  body:string ->
  created_at:Spice_session.Time.t ->
  unit ->
  (t, string) result
(** [propose ~id ~source ?title ~body ~created_at ()] is a proposed plan. Errors
    when [title] is present and empty or [body] is empty. *)

val id : t -> Id.t
(** [id t] is [t]'s plan id. *)

val source : t -> Source.t
(** [source t] is [t]'s provenance. *)

val title : t -> string option
(** [title t] is [t]'s optional title. *)

val body : t -> string
(** [body t] is [t]'s markdown plan body. *)

val status : t -> Status.t
(** [status t] is [t]'s lifecycle status. *)

val created_at : t -> Spice_session.Time.t
(** [created_at t] is [t]'s creation time. *)

val updated_at : t -> Spice_session.Time.t
(** [updated_at t] is [t]'s latest transition time, or {!created_at} while
    proposed. *)

val approve : approved_at:Spice_session.Time.t -> t -> (t, string) result
(** [approve ~approved_at t] approves proposed plan [t]. Errors unless [t] is
    proposed, or when [approved_at] is before {!updated_at} [t]. *)

val reject :
  rejected_at:Spice_session.Time.t -> ?reason:string -> t -> (t, string) result
(** [reject ~rejected_at ?reason t] rejects proposed plan [t]. Errors unless
    [t] is proposed, when a present [reason] is empty, or when [rejected_at] is
    before {!updated_at} [t]. *)

val supersede :
  superseded_at:Spice_session.Time.t -> by:Id.t -> t -> (t, string) result
(** [supersede ~superseded_at ~by t] marks [t] superseded by plan [by].

    Proposed, approved, and rejected plans may be superseded; an already
    superseded plan, [by] equal to {!id} [t], or [superseded_at] before
    {!updated_at} [t] error. This is what a re-proposal calls when the session
    already holds a proposed or approved plan. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same plan. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps plans to JSON objects, funneling through the constructors. *)

(** {1:host_tool Host tool} *)

module Proposal : sig
  (** Decoded model plan proposals.

      A proposal is the checked payload of {!tool}. The host supplies source,
      tool-call id, and creation time when saving it as a durable {!Plan.t}. *)

  type t
  (** The type for a checked [propose_plan] request. *)

  val make :
    id:Id.t -> ?title:string -> body:string -> unit -> (t, string) result
  (** [make ~id ?title ~body ()] is a checked proposal. Errors on an empty
      present [title] or empty [body]. This is the single validation path;
      {!jsont} and {!decode} funnel through it. *)

  val id : t -> Id.t
  (** [id t] is the proposed plan id. *)

  val title : t -> string option
  (** [title t] is the optional display title. *)

  val body : t -> string
  (** [body t] is the proposed plan body. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same proposal. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps proposals to JSON objects, funneling through {!make}. *)
end

val name : string
(** [name] is the model-visible plan proposal tool name. *)

val tool : Spice_llm.Tool.t
(** [tool] is the model-visible plan proposal tool declaration. *)

val decode : Spice_llm.Tool.Call.t -> (Proposal.t, string) result
(** [decode call] decodes [call]'s input as a plan proposal. Errors with a
    diagnostic when [call] does not target {!name} or its payload fails shape or
    proposal validation. *)

(** {1:resolution Resolution} *)

module Decision : sig
  (** A user's decision on a proposed plan.

      A decision is the client-side vocabulary of plan resolution: it says what
      the user chose, leaving the load-transition-save orchestration to the
      engine. *)

  type t = private
    | Approve
    | Reject of { reason : string option }  (** The type for a plan decision. *)

  type error = Empty_reason
  (** The type for an invalid decision. *)

  val approve : t
  (** [approve] accepts the proposed plan. *)

  val reject : t
  (** [reject] rejects the proposed plan without a reason. *)

  val reject_with_reason : string -> (t, error) result
  (** [reject_with_reason reason] rejects the plan with [reason]. Returns
      {!Empty_reason} when [reason] is empty. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error] formats a decision construction error. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same decision. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)
end
