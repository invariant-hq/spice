(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session transcript compaction policy and pressure.

    This module owns the request-independent compaction vocabulary: checked
    {!Policy} parameters and their model derivations, the {!Pressure} projection
    a pre-request trigger reads, and the {!type:result} of an installed durable
    compaction. It holds no store, client, or effect; the session interpreter
    consumes these values when it decides whether and how to summarize replay
    history, and the effectful summarization engine that produces a
    {!type:result} lives elsewhere. *)

module Policy : sig
  (** Checked, immutable parameters for automatic or explicit compaction. *)

  (** {1:types Types} *)

  type t
  (** The type for a compaction policy. Parameters are validated at construction
      ({!make}).

      A policy governs both triggering and summarization. [auto_limit], when
      present, enables pre-request compaction once a projected request reaches
      or exceeds the limit in estimated input tokens. [keep_turns] is the
      maximum number of trailing user-turn groups retained verbatim.
      [keep_tokens], when present, additionally caps that retained tail by the
      approximate token estimate. A summary request is sent to [model] when
      present (otherwise the turn's own model), prefixed by [prelude] when
      present, and capped at [summary_max_output_tokens] output tokens when
      present. *)

  (** {1:constructors Constructors} *)

  val make :
    ?model:Spice_llm.Model.t ->
    ?prelude:Spice_llm.Request.Prelude.t ->
    ?auto_limit:int ->
    ?keep_turns:int ->
    ?keep_tokens:int ->
    ?summary_max_output_tokens:int ->
    unit ->
    t
  (** [make ()] is a policy with the given parameters. [keep_turns] defaults to
      [2]; every other parameter defaults to absent — no automatic limit, no
      tail-token cap, no explicit summary model, prelude, or output cap.

      Raises [Invalid_argument] if [auto_limit] or [summary_max_output_tokens]
      is not positive, or if [keep_turns] or [keep_tokens] is negative. *)

  val default : t
  (** [default] configures no summary model, prelude, or limits and retains
      [keep_turns = 2] trailing turns. It is the policy of manual compaction,
      which triggers unconditionally and needs no automatic limit. *)

  val of_model :
    ?prelude:Spice_llm.Request.Prelude.t -> Spice_provider.Model.t -> t
  (** [of_model ?prelude model] is the standard execution policy derived from
      [model]'s declared catalog facts: {!auto_limit_of_model} as the automatic
      limit, a proportional [keep_tokens] tail budget when that limit is
      derivable, and a summary output cap bounded by the model's own maximum.
      This is the sole source of a runtime policy's [auto_limit], so the
      enforced trigger and any model-derived display of the limit agree. *)

  (** {1:queries Queries} *)

  val model : t -> Spice_llm.Model.t option
  (** [model t] is [t]'s explicit summary model, if any. *)

  val auto_limit : t -> int option
  (** [auto_limit t] is [t]'s pre-request compaction threshold in estimated
      input tokens, if enabled. It is the value the interpreter compares
      {!Pressure.projected_input} against. *)

  val keep_turns : t -> int
  (** [keep_turns t] is the number of trailing user-turn groups [t] retains
      verbatim. It defaults to [2]. *)

  val keep_tokens : t -> int option
  (** [keep_tokens t] is [t]'s additional token cap on the retained tail, if
      any. *)

  val summary_max_output_tokens : t -> int option
  (** [summary_max_output_tokens t] is [t]'s model output cap for the summary
      request, if any. *)

  val prelude : t -> Spice_llm.Request.Prelude.t option
  (** [prelude t] is [t]'s request prelude for summary requests, if any. *)

  (** {1:model Model derivations}

      Pure functions of a catalog model, independent of any {!t}. They are the
      derivation {!of_model} applies, exposed so an evidence surface (e.g.
      [spice debug model]) can report the limit and its provenance without
      constructing a policy. *)

  val auto_limit_of_model : Spice_provider.Model.t -> int option
  (** [auto_limit_of_model model] is the standard automatic-compaction limit
      derived from [model]'s declared context window less an output buffer, or
      [None] when the window is undeclared or too small for a buffer. *)

  val auto_limit_reason : Spice_provider.Model.t -> string
  (** [auto_limit_reason model] is the one-line provenance of
      {!auto_limit_of_model}[ model], including why compaction is disabled when
      the limit is [None]. *)
end

module Pressure : sig
  (** Context pressure: the projected size of the next request against a
      session's replay, and how that projection was grounded.

      A {!t} carries only the fact the pre-request trigger reads —
      {!projected_input}, compared against {!Policy.auto_limit}. The
      model-derived facts a status surface displays (a model's declared context
      window and {!Policy.auto_limit_of_model}) are not pressure and are not
      here: a caller with the model in hand reads them from the model directly.
      This keeps the enforced trigger and the display facts structurally
      distinct rather than bundled in one record. *)

  (** {1:types Types} *)

  type t
  (** The type for a context-pressure fact derived from a session's replay. *)

  (** {1:constructors Constructors} *)

  val of_state : ?request:Spice_llm.Request.t -> Spice_session.State.t -> t
  (** [of_state ?request state] is the pressure of [state]'s replay.

      When [state] has a provider-reported replay usage, the projection is
      usage-grounded ({!basis} is {!Spice_protocol.Event.Usage}): that usage
      plus the estimate of messages appended since the usage baseline. With no
      usage baseline the projection is an estimate
      ({!Spice_protocol.Event.Estimate}) of [request] when given — widening the
      projection to the full pending request — and otherwise of [state]'s
      current transcript. *)

  (** {1:queries Queries} *)

  val projected_input : t -> int
  (** [projected_input t] is the estimated input-token count of the next
      request. It is the value a pre-request trigger compares against
      {!Policy.auto_limit}. *)

  val basis : t -> Spice_protocol.Event.basis
  (** [basis t] is how {!projected_input} was grounded. The result is the
      protocol event basis; this observer is the total mapping from a pressure
      fact into {!Spice_protocol.Event}'s compaction basis, so a live emission
      carries the pressure's basis unchanged. *)
end

type result = {
  document : Spice_session_store.Document.t;
  compaction : Spice_session.Compaction.t;
}
(** The output of an installed compaction: [compaction] is the durable event and
    [document] is the saved document that now contains it. It is the shape the
    effectful summarization engine returns and the session interpreter installs;
    its public home is here because that engine has no interface of its own. *)
