(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Completed provider responses.

    A response records provider-reported metadata around the durable assistant
    message produced by a request. Add {!message} to a {!Transcript.t}; keep
    stop reasons, usage, provider ids, and reasoning summaries as response
    metadata.

    Live stream events are progress only. The assistant message stored here is
    the authoritative transcript fact. *)

module Stop : sig
  (** Normalized response stop reasons.

      Stop reasons explain why a provider completed successfully. Failures such
      as cancellation, transport errors, or provider errors are {!Error.t}
      values, not stop reasons. Provider-native stop labels may be retained
      separately on {!Response.t}. *)

  type t
  (** The type for provider-neutral stop reasons. *)

  type view =
    | End_turn
    | Tool_call
    | Length
    | Content_filter
    | Refusal
    | Other of string
        (** The type for inspecting stop reasons.

            [Other label] carries a non-empty lowercase label that is not
            reserved by a dedicated constructor. *)

  val end_turn : t
  (** [end_turn] is the ordinary successful end-of-turn stop reason. *)

  val tool_call : t
  (** [tool_call] is the stop reason for a response that requests tool calls. *)

  val length : t
  (** [length] is the stop reason for output-token exhaustion. *)

  val content_filter : t
  (** [content_filter] is the stop reason for provider content filtering. *)

  val refusal : t
  (** [refusal] is the stop reason for provider refusal. *)

  val other : string -> t
  (** [other label] is an unrecognized stop reason.

      Raises [Invalid_argument] if [label] is invalid or reserved. *)

  val label : t -> string
  (** [label t] is [t]'s stable lowercase label.

      Labels start with a lowercase ASCII letter and then contain lowercase
      ASCII letters, digits, or ['_']. *)

  val of_label : string -> t option
  (** [of_label label] decodes [label].

      Reserved labels decode to their canonical values. Unknown valid labels
      decode to [Some (other label)]. Invalid labels decode to [None]. *)

  val view : t -> view
  (** [view t] is [t]'s inspectable view. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same label. *)

  val compare : t -> t -> int
  (** [compare a b] orders stop reasons by label. The order is compatible with
      {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps stop reasons to JSON strings.

      Decoding errors if the string is not a valid stop label. *)
end

type t
(** The type for completed provider responses. *)

val make :
  model:Model.t ->
  ?response_model:string ->
  ?response_id:string ->
  ?provider_stop:string ->
  ?stop:Stop.t ->
  ?usage:Usage.t ->
  ?reasoning_summary:string list ->
  Message.Assistant.t ->
  t
(** [make ~model ?response_model ?response_id ?provider_stop ?stop ?usage
     ?reasoning_summary assistant] is a completed response.

    [model] is the requested model, not necessarily the provider-selected model
    that produced the response. [assistant] may contain text, tool calls,
    provider-owned reasoning parts, or be {!Message.Assistant.empty}.
    [response_model], when present, records the provider-selected model id.
    [response_id], when present, records a provider response id.
    [provider_stop], when present, records the provider-native stop label.
    [stop], when present, records the normalized stop reason.
    [reasoning_summary] defaults to [[]] and is metadata, not transcript
    content.

    Raises [Invalid_argument] if [response_model], [response_id],
    [provider_stop], or a reasoning summary is empty when present. *)

val assistant : t -> Message.Assistant.t
(** [assistant t] is [t]'s durable assistant message. *)

val message : t -> Message.t
(** [message t] is [assistant t] as a transcript message. *)

val texts : t -> string list
(** [texts t] is the visible assistant text blocks in order. *)

val text : ?sep:string -> t -> string
(** [text ?sep t] concatenates {!texts}[ t] with [sep].

    [sep] defaults to the empty string. Responses with no text produce [""]. *)

val tool_calls : t -> Tool.Call.t list
(** [tool_calls t] is the complete assistant tool calls in order. *)

val has_tool_calls : t -> bool
(** [has_tool_calls t] is [true] iff {!tool_calls}[ t] is non-empty. *)

val model : t -> Model.t
(** [model t] is the requested model. *)

val response_model : t -> string option
(** [response_model t] is the provider-selected model id, if known. *)

val response_id : t -> string option
(** [response_id t] is the provider response id, if known. *)

val provider_stop : t -> string option
(** [provider_stop t] is the provider-native stop label, if known. *)

val stop : t -> Stop.t option
(** [stop t] is the normalized stop reason, if known. *)

val usage : t -> Usage.t option
(** [usage t] is the provider-reported usage, if any. *)

val reasoning_summary : t -> string list
(** [reasoning_summary t] is provider-approved reasoning summary text in order.
*)

val jsont : t Jsont.t
(** [jsont] maps responses to JSON objects.

    Decoding errors if the object violates {!make}. *)
