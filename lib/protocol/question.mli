(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The user-question host tool.

    A question is a product-level host-tool call. It is represented in
    {!Spice_session} only by an ordinary assistant tool call and the later
    model-visible tool result; there is no separate durable question artifact.

    Use {!decode} to validate an [ask_user] call and {!answer_text} to produce
    the text stored in the answering tool result. This module satisfies
    {!Call.HOST_TOOL} with {!Request.t} as its request. *)

module Option : sig
  (** One presented answer choice for a structured question. *)

  type t
  (** The type for a checked question option.

      Invariant: [label] is non-empty and, when present, [description] is
      non-empty. The [label] is the text sent back to the model when the option
      is chosen; the [description] is optional muted help beside it. *)

  val make : label:string -> ?description:string -> unit -> (t, string) result
  (** [make ~label ?description ()] is a checked option. Errors when [label] is
      empty or [description] is present and empty. This is the single validation
      path; {!jsont} funnels through it. *)

  val label : t -> string
  (** [label t] is the option's label — the text returned to the model when it
      is selected. *)

  val description : t -> string option
  (** [description t] is the option's optional descriptive help text. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same option. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps options to JSON objects, funneling through {!make}. *)
end

module Request : sig
  (** Decoded user-question requests. *)

  type t
  (** The type for a checked [ask_user] request.

      The question text is non-empty and is intended for direct presentation to
      the user. An optional [header], a list of [options] the user picks from,
      and a [multi] flag carry presentation structure; the answer stays text
      either way, so a request grows structure but the answer waist
      ({!Spice_protocol.Command.Answer}) does not. *)

  val make :
    ?header:string ->
    question:string ->
    ?options:Option.t list ->
    ?multi:bool ->
    unit ->
    (t, string) result
  (** [make ?header ~question ?options ?multi ()] is a checked user question.
      Errors when [question] is empty or [header] is present and empty.
      [options] defaults to the empty list (a free-text question) and [multi] to
      [false] (single-select). This is the single validation path; {!jsont}
      funnels through it. *)

  val header : t -> string option
  (** [header t] is the optional headline shown above the question, if any. *)

  val question : t -> string
  (** [question t] is the user-facing question text. *)

  val options : t -> Option.t list
  (** [options t] is the presented answer choices, empty for a free-text
      question. *)

  val multi : t -> bool
  (** [multi t] is [true] iff several options may be selected. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same request. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps requests to JSON objects, funneling through {!make}.
      [options] and [multi] are absent-tolerant, so a bare [{ question }]
      payload decodes to a free-text question. *)
end

(** {1:host_tool Host tool} *)

val name : string
(** [name] is the model-visible question tool name. *)

val tool : Spice_llm.Tool.t
(** [tool] is the model-visible question tool declaration. Its input schema
    requires exactly a [question] string. *)

val decode : Spice_llm.Tool.Call.t -> (Request.t, string) result
(** [decode call] decodes [call]'s input as a question request. Errors with a
    diagnostic when [call] does not target {!name} or its payload fails shape or
    request validation. *)

val answer_text : string -> (string, string) result
(** [answer_text text] is the model-visible tool-result text for answer [text].
    Errors when [text] is empty. *)
