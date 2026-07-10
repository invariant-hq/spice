(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-visible messages.

    Messages are inert transcript facts. They do not contain session ids, item
    ids, timestamps, executable tools, permission state, transport handles, or
    UI state. Construct messages with the smart constructors in this module,
    then use {!Transcript} to check message order and tool-call/result grammar.
    Private variants are exposed for inspection, not unchecked construction. *)

module Assistant : sig
  (** Assistant messages: ordered output parts.

      An assistant message carries visible text, model-requested tool calls, and
      durable provider-owned {!Reasoning.t} parts in model order. Construct with
      {!make}, {!text}, or {!empty}. *)

  module Reasoning : sig
    (** Provider-owned reasoning transcript parts. *)

    type t
    (** The type for provider-owned reasoning transcript parts.

        Reasoning parts are durable assistant output that a provider may require
        on a later request, such as signed thinking or encrypted reasoning
        content. They are model-visible replay facts, unlike
        {!Response.reasoning_summary}, which is response metadata for logs and
        UI. Provider adapters own the semantics of each optional field. *)

    val make :
      ?id:string ->
      ?summary:string ->
      ?text:string ->
      ?encrypted:string ->
      ?signature:string ->
      ?metadata:Jsont.json ->
      unit ->
      t
    (** [make ?id ?summary ?text ?encrypted ?signature ?metadata ()] is a
        reasoning part.

        Raises [Invalid_argument] if an optional string is empty, or if no field
        is present. *)

    val id : t -> string option
    (** [id t] is the provider item id, if any. *)

    val summary : t -> string option
    (** [summary t] is provider-approved summary text, if any. *)

    val text : t -> string option
    (** [text t] is provider-owned reasoning text, if any. *)

    val encrypted : t -> string option
    (** [encrypted t] is opaque encrypted reasoning content, if any. *)

    val signature : t -> string option
    (** [signature t] is a provider signature over the reasoning content, if
        any. *)

    val metadata : t -> Jsont.json option
    (** [metadata t] is provider-specific inert metadata, if any. *)

    val jsont : t Jsont.t
    (** [jsont] maps reasoning parts to JSON objects.

        Decoding errors if the object violates {!make}. *)
  end

  type part = private
    | Text of string
    | Tool_call of Tool.Call.t
    | Reasoning of Reasoning.t
        (** The type for assistant output parts.

            Text parts are non-empty. Tool calls and reasoning parts are durable
            model-visible assistant output. *)

  val text_part : string -> part
  (** [text_part s] is visible assistant text [s].

      Raises [Invalid_argument] if [s] is empty. *)

  val tool_call : Tool.Call.t -> part
  (** [tool_call call] is a model-requested tool call part. *)

  val reasoning_part : Reasoning.t -> part
  (** [reasoning_part reasoning] is a durable provider-owned reasoning part. *)

  type t
  (** The type for assistant messages. *)

  val empty : t
  (** [empty] is an assistant message with no visible text, tool calls, or
      provider-owned reasoning parts.

      This represents successful provider turns that intentionally produce no
      assistant content, for example a content-filter or max-token finish before
      any output. *)

  val make : part list -> t
  (** [make parts] is an assistant message preserving [parts] in model order.

      Raises [Invalid_argument] if [parts] is empty or a part violates its
      invariant. *)

  val text : string -> t
  (** [text s] is an assistant message with one visible text part.

      Raises [Invalid_argument] if [s] is empty. *)

  val parts : t -> part list
  (** [parts t] is [t]'s output in model order. *)

  val tool_calls : t -> Tool.Call.t list
  (** [tool_calls t] is [t]'s tool calls in output order. *)

  val texts : t -> string list
  (** [texts t] is [t]'s visible text parts in output order. *)

  val reasonings : t -> Reasoning.t list
  (** [reasonings t] is [t]'s durable reasoning parts in output order. *)

  val jsont : t Jsont.t
  (** [jsont] maps assistant messages to JSON objects.

      Decoding maps an empty [parts] list to {!empty} and errors if any part
      violates its invariant. *)
end

(** The type for model-visible transcript messages.

    Instruction strings and content lists are non-empty. Assistant messages may
    be empty through {!Assistant.empty}. Tool-result order is checked by
    {!Transcript}. *)
type t = private
  | System of string
  | Developer of string
  | User of Content.t list
  | Assistant of Assistant.t
  | Tool_result of Tool.Result.t

val system : string -> t
(** [system s] is a system instruction.

    Raises [Invalid_argument] if [s] is empty. *)

val developer : string -> t
(** [developer s] is a developer instruction.

    Raises [Invalid_argument] if [s] is empty. *)

val user : Content.t list -> t
(** [user content] is a user message.

    Raises [Invalid_argument] if [content] is empty. *)

val user_text : string -> t
(** [user_text s] is a user message with one text block.

    Raises [Invalid_argument] if [s] is empty. *)

val assistant : Assistant.t -> t
(** [assistant a] is assistant message [a]. *)

val assistant_text : string -> t
(** [assistant_text s] is an assistant text message.

    Raises [Invalid_argument] if [s] is empty. *)

val tool_result : Tool.Result.t -> t
(** [tool_result r] is a tool-result message. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] contain the same durable message
    data. *)

val jsont : t Jsont.t
(** [jsont] maps messages to JSON objects.

    Decoding errors if the object violates the corresponding message
    constructor. *)
