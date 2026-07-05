(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable model-replay compactions.

    A compaction records that the session's model-visible replay transcript was
    replaced by a smaller checked transcript. It does not contain the
    pre-compaction display history. Durable event logs and host projections keep
    the older events available for UI, audit, export, and fork workflows. *)

module Reason : sig
  (** Durable reasons for installing a compaction. *)

  type t =
    | User_requested  (** The user explicitly requested compaction. *)
    | Context_pressure
        (** The host compacted before a model request because the projected
            request was near the context limit. *)
    | Context_overflow
        (** The host compacted after a provider reported context overflow. *)
    | Model_downshift
        (** The host compacted because the next request uses a model with a
            smaller context window. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same compaction reason. *)

  val to_string : t -> string
  (** [to_string r] is [r]'s stable lowercase tag, the same spelling {!jsont}
      encodes: ["user_requested"], ["context_pressure"], ["context_overflow"],
      or ["model_downshift"]. CLI and event surfaces use this instead of
      re-spelling the enum. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a compaction reason for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps compaction reasons to JSON values and rejects unknown reason
      tags. *)
end

(** {1:metadata Metadata} *)

module Token_estimate : sig
  type t
  (** The type for token facts associated with an installed compaction.

      All present values are non-negative estimates or provider-reported counts.
  *)

  val make :
    ?before:int ->
    ?after:int ->
    ?summary_input:int ->
    ?summary_output:int ->
    unit ->
    t
  (** [make ?before ?after ?summary_input ?summary_output ()] is token metadata
      for a compaction.

      [before] and [after] describe projected replay input tokens before and
      after installing the compaction. [summary_input] and [summary_output]
      describe the summarization request itself.

      Raises [Invalid_argument] if no count is present, or if any present count
      is negative. *)

  val before : t -> int option
  (** [before t] is the projected replay input token count before compaction, if
      known. *)

  val after : t -> int option
  (** [after t] is the projected replay input token count after compaction, if
      known. *)

  val summary_input : t -> int option
  (** [summary_input t] is the summarization request input token count, if
      known. *)

  val summary_output : t -> int option
  (** [summary_output t] is the summarization response output token count, if
      known. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same token estimate. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats token estimates for diagnostics. The output is not stable
      storage syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps token estimates to JSON values. Decoding validates the same
      non-empty and non-negative count invariant as {!make}. *)
end

module Range : sig
  (** Durable message-count metadata for a compaction. *)

  type t
  (** The type for message counts selected by a compaction.

      Counts describe the transcript selected by the compaction executor, not
      durable event-log positions. *)

  val make : summarized_messages:int -> retained_tail_messages:int -> t
  (** [make ~summarized_messages ~retained_tail_messages] is compaction range
      metadata.

      Raises [Invalid_argument] if either count is negative. *)

  val summarized_messages : t -> int
  (** [summarized_messages t] is the number of earlier transcript messages
      replaced by the summary boundary. When summary generation had to drop
      oldest input to fit the summary model's context, dropped messages still
      count here: they are gone from replay either way. *)

  val retained_tail_messages : t -> int
  (** [retained_tail_messages t] is the number of later transcript messages
      retained verbatim in the replacement transcript. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same range metadata. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats range metadata for diagnostics. The output is not stable
      storage syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps range metadata to JSON values. Decoding validates the same
      non-negative count invariant as {!make}. *)
end

type t
(** The type for a durable compaction.

    The replacement transcript is model replay state and must be request-ready.
    Installing the compaction through {!State.apply} also requires the current
    transcript to be request-ready. Active turns, if any, remain active; the
    compaction changes replay history, not turn lifecycle. *)

val make :
  reason:Reason.t ->
  summary:string ->
  transcript:Spice_llm.Transcript.t ->
  ?model:Spice_llm.Model.t ->
  ?tokens:Token_estimate.t ->
  ?range:Range.t ->
  unit ->
  t
(** [make ~reason ~summary ~transcript ?model ?tokens ?range ()] is a compaction
    that replaces the model replay transcript with [transcript].

    [summary] is a human-readable account of the compacted content. It is
    durable metadata and is normally also present in [transcript] in whatever
    model-visible form the compaction executor chooses.

    Raises [Invalid_argument] if [summary] is empty or if [transcript] is not
    request-ready. Optional metadata is already checked by its constructors. *)

val reason : t -> Reason.t
(** [reason t] is the reason [t] was installed. *)

val summary : t -> string
(** [summary t] is [t]'s durable compaction summary. *)

val transcript : t -> Spice_llm.Transcript.t
(** [transcript t] is [t]'s checked replacement model replay transcript. *)

val model : t -> Spice_llm.Model.t option
(** [model t] is the model used to produce [t]'s summary, if known. *)

val tokens : t -> Token_estimate.t option
(** [tokens t] is [t]'s token metadata, if known. *)

val range : t -> Range.t option
(** [range t] is [t]'s range metadata, if known. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same compaction. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a compaction for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps compactions to JSON values. Decoding validates the same summary
    and transcript invariants as {!make}. *)
