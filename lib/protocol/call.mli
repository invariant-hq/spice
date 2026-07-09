(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host-tool call classification.

    Every host tool — {!Question}, {!Plan}, {!Todo}, {!Goal}, {!Subagent} —
    exposes the same {!HOST_TOOL} shape, so a surface learns it once.
    {!classify} decodes an arbitrary model tool call into the single {!t} sum,
    replacing the string matching against tool names that each consumer carried.

    Classification never fails: a call that targets a known host tool but
    carries an undecodable payload becomes {!Invalid}, so the boundary can
    surface a model-visible correction rather than dropping the call. *)

(** The shape shared by every host tool.

    A host tool declares a model-visible {!tool} under a stable {!name} and
    {!decode}s a matching call into its request type. Decoding validates shape
    and invariants through the type's smart constructor — the single validation
    path — and reports failures as a diagnostic string, which becomes the
    model-visible tool-result text. *)
module type HOST_TOOL = sig
  type request
  (** The type for a decoded, validated request. *)

  val name : string
  (** [name] is the model-visible tool name. *)

  val tool : Spice_llm.Tool.t
  (** [tool] is the model-visible tool declaration. *)

  val decode : Spice_llm.Tool.Call.t -> (request, string) result
  (** [decode call] decodes [call]'s input as a {!request}. Errors with a
      diagnostic when [call] does not target {!name} or its payload fails shape
      or invariant validation. *)
end

module Kind : sig
  (** The payload-free enumeration of the built-in host tools.

      A kind names a host tool without its request payload. It exists so the
      {e offer} table ({!Mode.host_tools}) and the {e recognition} set (mapping
      {!all} through {!tool}) live once and agree by construction. It is
      deliberately distinct from {!type:t}: a kind names a tool, while a
      {!type:t} classifies a concrete call. *)

  type t =
    | Question
    | Plan
    | Todo
    | Goal
    | Subagent
    | Subagent_wait
    | Subagent_cancel
    | Subagent_message
    | Subagent_message_parent  (** The type for a host-tool kind. *)

  val all : t list
  (** [all] is every host-tool kind. *)

  val tool : t -> Spice_llm.Tool.t
  (** [tool k] is [k]'s model-visible tool declaration. This is the single
      kind-to-declaration map. *)

  val name : t -> string
  (** [name k] is [k]'s stable model-visible tool name. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same kind. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [k] for diagnostics. *)
end

(** The type for a classified host-tool call. *)
type t =
  | Question of Question.Request.t  (** A pending user question. *)
  | Plan of Plan.Proposal.t  (** A pending plan proposal. *)
  | Todo of Todo.t  (** A todo-list replacement. *)
  | Goal of Goal.Update.t  (** A goal complete/blocked report. *)
  | Subagent of Subagent.Spawn.t  (** A child-run spawn request. *)
  | Subagent_wait of Subagent.Wait.Request.t
      (** A block-for-run-results request. *)
  | Subagent_cancel of Subagent.Cancel.Request.t
      (** A run interruption request. *)
  | Subagent_message of Subagent.Message.Request.t
      (** A steer-or-resume message to a run. *)
  | Subagent_message_parent of Subagent.Message_parent.Request.t
      (** A child's question to its parent; parks the child turn. *)
  | Invalid of { name : string; error : string }
      (** A recognized host tool named [name] whose payload failed to decode;
          [error] is the diagnostic and eventual model-visible correction. *)

val classify : Spice_llm.Tool.Call.t -> t option
(** [classify call] classifies [call] as a host-tool call.

    [None] for calls that are not host tools (ordinary executable tools). A call
    targeting a known host tool always classifies, to {!Invalid} when its
    payload cannot be decoded. Composed with {!Spice_session.Waiting.t}, this is
    the single host-call classification path. *)

val answerable_question : t -> string option
(** [answerable_question t] is the text to present when [t] parks the turn on
    the question boundary: the [ask_user] question for a valid call, or a
    decode-failure description ["Invalid question: " ^ error] for an invalid one
    (still answerable, so the user can unblock). [None] for any other call.

    Folds the {!Invalid} case so no consumer re-compares the tool name. Raw-call
    sites compose it over {!classify}:
    [Option.bind (classify call) answerable_question]. *)

val answer_text : t -> string -> (string, string) result
(** [answer_text call answer] renders a raw user [answer] for a parked [call].
    Questions, including an invalid [ask_user] payload, use
    {!Question.answer_text}; {!Subagent_message_parent} preserves the parent's
    message verbatim. Errors when [answer] is empty or [call] has no user-answer
    contract. *)

val plan_proposal : t -> Plan.Proposal.t option
(** [plan_proposal t] is the proposal when [t] is a well-formed [propose_plan],
    else [None]. An invalid proposal is [None]: it is not a plan the surface can
    render or resolve. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)
