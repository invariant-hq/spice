(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable tool claim facts.

    A tool claim records that the host has claimed an executable model tool call
    and may have performed external effects for it. This is distinct from the
    model-visible tool call itself: a tool call is requested by the model, while
    a claim is the host's durable pre-effect record for running it.

    Tool claims are durable so a resumed session never automatically repeats a
    possibly non-idempotent tool after a crash. A started claim blocks the
    active turn until a matching finished claim records the model-visible
    result. A turn cannot finish while one of its claims is unresolved. *)

(** {1:ids Identifiers} *)

module Id : sig
  type t
  (** The type for stable tool claim identifiers.

      Invariant: an identifier's stable textual form is non-empty. *)

  val of_string : string -> t
  (** [of_string s] is [s] as a tool claim id.

      Raises [Invalid_argument] if [s] is empty. *)

  val to_string : t -> string
  (** [to_string id] is [id]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same tool claim id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representations.

      The order is compatible with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an id for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps tool claim ids to JSON strings. Decoding validates the same
      non-empty invariant as {!of_string}. *)
end

(** {1:started Started tool claims} *)

module Started : sig
  type t
  (** The type for a durable started tool claim.

      State replay additionally requires [turn] to be the active unfinished turn
      and [call] to be pending in the transcript. *)

  val make : id:Id.t -> turn:Turn.Id.t -> call:Spice_llm.Tool.Call.t -> t
  (** [make ~id ~turn ~call] is a started claim of model tool call [call] during
      [turn]. *)

  val id : t -> Id.t
  (** [id t] is [t]'s tool claim id. *)

  val turn : t -> Turn.Id.t
  (** [turn t] is the turn that owns [t]. *)

  val call : t -> Spice_llm.Tool.Call.t
  (** [call t] is the model tool call executed by [t]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same started claim data.
  *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. The output is not stable storage syntax.
  *)

  val jsont : t Jsont.t
  (** [jsont] maps started claims to JSON values. Replay validity is checked by
      {!State.apply}. *)
end

(** {1:finished Finished tool claims} *)

module Finished : sig
  type t
  (** The type for a durable finished tool claim.

      State replay requires [id] to name a pending started claim and [result] to
      answer that claim's exact tool call id and name. [output] records erased
      host evidence for product UI replay when the tool produced any. *)

  val make :
    id:Id.t -> output:Spice_tool.Output.t option -> Spice_llm.Tool.Result.t -> t
  (** [make ~id ~output result] records [result] as the model-visible result of
      tool claim [id].

      [output] is the erased host output that produced [result], if the tool
      produced any. It is not used for model replay, but allows restored product
      UI to render the same typed evidence as the live UI. *)

  val id : t -> Id.t
  (** [id t] is the tool claim id [t] finishes. *)

  val result : t -> Spice_llm.Tool.Result.t
  (** [result t] is the model-visible tool result produced by [t]. *)

  val output : t -> Spice_tool.Output.t option
  (** [output t] is the erased host output that produced {!result}, if the tool
      produced any. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same finished claim
      data. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. The output is not stable storage syntax.
  *)

  val jsont : t Jsont.t
  (** [jsont] maps finished claims to JSON values. Replay validity is checked by
      {!State.apply}. *)
end

val matches : Started.t -> Finished.t -> bool
(** [matches started finished] is [true] iff [finished] answers [started]. *)
