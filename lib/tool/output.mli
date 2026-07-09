(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-projectable tool outputs.

    Tool handlers return typed OCaml values inside {!Result.t}. An
    {!type:encoder} converts those typed values to {!type:t}, the erased output
    shape returned by {!Spice_tool.Call.run}.

    Text is the authoritative projection because every model and log sink can
    consume it. JSON is optional structured projection data for hosts that need
    machine-readable details; callers must not reconstruct required behavior by
    parsing {!text}.

    Outputs may additionally retain the typed value they were rendered from,
    keyed by a [Type.Id] witness owned by the producing tool. The retained value
    is in-memory host evidence: it is never serialized, compared, or shown to
    models, and only the owning tool's witness can recover it with {!value}. *)

type t
(** The type for erased tool output returned by a tool call.

    Values always contain non-empty authoritative text. They may also contain
    structured JSON, a truncation marker, and a retained typed value.
    "Non-empty" means at least one character; whitespace-only text is accepted.
*)

type value
(** The type for retained typed values, packed with their witness. *)

val pack : 'a Type.Id.t -> 'a -> value
(** [pack id typed] packs [typed] with the witness [id] for {!make}. *)

val make :
  text:string ->
  ?json:Jsont.json ->
  ?truncated:bool ->
  ?value:value ->
  unit ->
  t
(** [make ~text ?json ?truncated ?value ()] is an erased tool output.

    [json] is already-encoded structured projection data and is retained as
    provided. [truncated] is [true] iff [text] omits information because of a
    size or policy limit; it defaults to [false]. The marker describes the text
    projection, not necessarily the optional JSON projection. [value], when
    present, is the retained typed value recoverable with {!val-value}.

    Raises [Invalid_argument] if [text] is empty. *)

val value : 'a Type.Id.t -> t -> 'a option
(** [value id t] is the typed value retained by [t] iff it was packed with the
    same witness [id]. *)

val text : t -> string
(** [text t] is [t]'s authoritative model-visible text.

    The string is non-empty. *)

val json : t -> Jsont.json option
(** [json t] is [Some json] if [t] carries structured projection data and [None]
    otherwise.

    The JSON value is host-facing projection data. The model-visible content is
    still {!text}. *)

val truncated : t -> bool
(** [truncated t] is [true] iff [text t] was truncated. *)

val jsont : t Jsont.t
(** [jsont] maps erased outputs to durable JSON.

    The mapping preserves {!text}, {!json}, and {!truncated}. Retained typed
    values are in-memory evidence and are not serialized. This is the session
    and audit-log shape; hosts that need replayable UI or audit data must place
    that data in {!text} or {!json} before the output is written. *)

type 'a encoder = 'a -> t
(** The type for typed output encoders from ['a] to erased {!type:t}.

    Encoders are passed to {!Spice_tool.make}; {!Spice_tool.Call.run} applies
    the encoder to any typed output carried by the handler's terminal
    {!Result.t}. Build one directly from {!make}. *)
