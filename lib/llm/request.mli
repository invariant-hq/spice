(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model requests.

    A request combines a checked {!Transcript.t} with the current model, the
    model-visible tools available for this request, and provider-neutral request
    options. Provider clients interpret requests; they do not repair transcript
    grammar, execute tools, or mutate session state.

    Construct requests with {!make}. Recoverable construction failures are
    returned as {!Error.t}; the exception-raising constructors are for
    programmer-local static setup only. *)

module Options : sig
  (** Provider-neutral request options: tool-choice policy, reasoning effort,
      output shape, and sampling caps.

      Construct with {!make}; {!default} is the empty option set. Provider
      adapters map these to their own request fields. *)

  type tool_choice =
    | Auto
    | No_tools
    | Required
    | Tool of string
        (** The type for tool-choice policy.

            [Auto] lets the provider choose whether to call tools. [No_tools]
            disables tool calls for this request even when declarations are
            supplied. [Required] requires at least one tool call. [Tool name]
            requires the named declared tool. Request construction validates
            [Required] and [Tool name] against the request's declarations. *)

  module Reasoning_effort : sig
    (** Provider-neutral reasoning effort levels and their stable spellings. *)

    type t =
      | Disabled
      | Minimal
      | Low
      | Medium
      | High
      | Extra_high
      | Max
          (** The type for provider-neutral reasoning effort.

              [None] at the option level means provider default. [Disabled]
              explicitly asks the provider to disable reasoning when supported.
              Provider adapters must reject unsupported effort levels rather
              than silently lowering them. *)

    val to_string : t -> string
    (** [to_string e] is [e]'s stable spelling: ["none"], ["minimal"], ["low"],
        ["medium"], ["high"], ["xhigh"], or ["max"].

        This is the single reasoning-effort vocabulary: request-options storage,
        provider declarations, CLI flags, and diagnostics all use it. *)

    val of_string : string -> t option
    (** [of_string s] decodes a stable spelling; see {!to_string}. Unknown
        spellings decode to [None]. *)

    val all : t list
    (** [all] are the efforts in declaration order. Spelling enumerations for
        diagnostics derive from [all] and {!to_string}. *)

    val jsont : t Jsont.t
    (** [jsont] maps efforts to their stable spellings. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats {!to_string}[ t]. *)
  end

  type response_format =
    | Text
    | Json_schema of { name : string; schema : Jsont.json; strict : bool }
        (** The type for requested assistant output shape.

            [Json_schema] requests JSON output matching [schema]. [schema] must
            be a JSON object, but JSON Schema semantics are not validated by
            [spice.llm]. [strict] is passed through for provider adapters that
            support strict schema adherence. *)

  type t
  (** The type for provider-neutral request options. *)

  val default : t
  (** [default] is [make ()]. *)

  val make :
    ?tool_choice:tool_choice ->
    ?max_output_tokens:int ->
    ?temperature:float ->
    ?reasoning_effort:Reasoning_effort.t ->
    ?response_format:response_format ->
    unit ->
    t
  (** [make ()] is a checked option set.

      Raises [Invalid_argument] if [Tool name] has an invalid tool name,
      [max_output_tokens] is non-positive, [temperature] is negative or not
      finite, or [Json_schema] has an empty name or non-object schema. *)

  val tool_choice : t -> tool_choice
  (** [tool_choice t] is [t]'s tool-choice policy. *)

  val max_output_tokens : t -> int option
  (** [max_output_tokens t] is [t]'s output-token cap, if any. *)

  val temperature : t -> float option
  (** [temperature t] is [t]'s sampling temperature, if any. *)

  val reasoning_effort : t -> Reasoning_effort.t option
  (** [reasoning_effort t] is [t]'s requested reasoning effort, if any. *)

  val response_format : t -> response_format
  (** [response_format t] is [t]'s requested assistant output shape. *)

  val jsont : t Jsont.t
  (** [jsont] maps request options to JSON objects.

      Decoding errors if the object violates {!make}. *)
end

module Error : sig
  (** Request construction errors.

      Returned by {!make} and the {!Prelude} constructors as structured data;
      handle them by matching, not by parsing {!message}. *)

  type t =
    | Empty_transcript
    | Invalid_prelude_message of Message.t
    | Pending_tool_results of Tool.Call.t list
    | Duplicate_tool of string
    | Tool_choice_without_tools
    | Unknown_tool_choice of string
        (** The type for request construction errors.

            These are user- or state-boundary errors. They should be handled as
            data rather than by parsing {!message}. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

module Prelude : sig
  (** Host-generated model-visible request context.

      A prelude is sent before the transcript with a request, but it is not part
      of the checked conversation transcript. It is for host-owned instructions
      and context such as project instructions, workflow mode instructions,
      environment context, and other request-scoped context. Prelude messages
      remain request-scoped and must not be appended back to the transcript.

      Provider adapters that need the full model-visible message list should use
      {!messages} on the containing request. *)

  type t
  (** The type for checked request prelude messages.

      Accepted messages are {!Message.System}, {!Message.Developer}, and
      {!Message.User}. Prelude messages are not checked against transcript
      tool-call/result grammar and cannot contain assistant or tool-result
      facts. *)

  val empty : t
  (** [empty] is the empty request prelude. *)

  val make : Message.t list -> (t, Error.t) result
  (** [make messages] is a checked request prelude.

      Message order is preserved.

      Errors with {!Error.Invalid_prelude_message} if [messages] contains an
      assistant or tool-result message. *)

  val append : t -> Message.t list -> (t, Error.t) result
  (** [append t messages] is [t] with [messages] appended after [t]'s messages.

      [messages] is checked as in {!make} and its order is preserved.

      Errors with {!Error.Invalid_prelude_message} if [messages] contains an
      assistant or tool-result message. *)

  val messages : t -> Message.t list
  (** [messages t] is [t]'s checked message list in provider order. *)
end

type t
(** The type for checked model requests. *)

val make :
  model:Model.t ->
  ?prelude:Prelude.t ->
  ?tools:Tool.t list ->
  ?options:Options.t ->
  ?cache_key:string ->
  Transcript.t ->
  (t, Error.t) result
(** [make ~model ?prelude ?tools ?options ?cache_key transcript] is a checked
    request.

    [prelude] defaults to {!Prelude.empty}. [tools] defaults to [[]]. [options]
    defaults to {!Options.default}. The model-visible message order is the
    prelude messages followed by the transcript messages; see {!messages}.
    [prelude] is request-scoped host context and is not part of [transcript].
    The full transcript is retained on the request. [cache_key], when present,
    is a non-empty stable conversation key that providers may use as a
    prompt-cache routing hint; it never changes request semantics.

    Errors with structured {!Error.t} if [transcript] is empty, [transcript] is
    awaiting tool results, [tools] contains duplicate names, [Required] is used
    with no tools, or [Tool name] names an undeclared tool. *)

val make_exn :
  model:Model.t ->
  ?prelude:Prelude.t ->
  ?tools:Tool.t list ->
  ?options:Options.t ->
  ?cache_key:string ->
  Transcript.t ->
  t
(** [make_exn ~model ?prelude ?tools ?options ?cache_key transcript] is
    [make ~model ?prelude ?tools ?options ?cache_key transcript].

    Raises [Invalid_argument] if the request cannot be constructed. Prefer
    {!make} at user-input, persistence, provider, or session boundaries. *)

val append_prelude : t -> Message.t list -> (t, Error.t) result
(** [append_prelude t messages] is [t] with [messages] appended to its prelude.

    The request model, tool declarations, options, cache key, and transcript are
    preserved. The appended messages are checked with {!Prelude.append}, and the
    resulting request is checked with the same invariants as {!make}. On
    success, {!messages} of the result is the original prelude messages, then
    [messages], then the original transcript messages. *)

val model : t -> Model.t
(** [model t] is [t]'s requested model. *)

val tools : t -> Tool.t list
(** [tools t] are [t]'s model-visible tool declarations. *)

val options : t -> Options.t
(** [options t] are [t]'s request options. *)

val prelude : t -> Prelude.t
(** [prelude t] is [t]'s host-generated request context. *)

val transcript : t -> Transcript.t
(** [transcript t] is [t]'s checked model-visible history. *)

val messages : t -> Message.t list
(** [messages t] is the full provider-order message list:
    [Prelude.messages (prelude t) @ Transcript.messages (transcript t)].

    This is the common request projection for providers that reconstruct the
    complete prompt. Provider-specific APIs may still split or hoist parts of
    the prelude explicitly, but the ordering contract is the same. *)

val cache_key : t -> string option
(** [cache_key t] is [t]'s stable prompt-cache routing key, if any. *)
