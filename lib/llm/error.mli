(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Provider-boundary errors.

    Errors classify failures that occur while interpreting a {!Request.t} or
    consuming a {!Stream.t}. They are recoverable data values and are suitable
    for session state, logs, and CLI diagnostics. Request construction errors
    remain local to {!Request.Error}. *)

type phase =
  | Startup
  | Stream
      (** The type for provider failure phases.

          [Startup] means the provider failed before its semantic stream began.
          [Stream] means the provider failed after stream handoff. *)

type kind =
  | Cancelled
  | Auth
  | Quota
  | Rate_limited
  | Context_overflow
  | Invalid_request
  | Unsupported
  | Content_policy
  | Transport
  | Timeout
  | Decode
  | Malformed_stream
  | Provider
  | Other of string
      (** The type for provider-neutral error classes.

          [Other label] carries a non-empty lowercase label distinct from the
          labels of the dedicated constructors. Use a dedicated constructor when
          one exists; reserve [Other] for adapter-specific classes that still
          need structured handling. *)

type t
(** The type for provider-boundary errors. *)

val make :
  kind:kind ->
  ?phase:phase ->
  ?provider:Provider.t ->
  ?status:int ->
  ?request_id:string ->
  ?redacted_body:string ->
  string ->
  t
(** [make ~kind ?phase message] is a provider-boundary error.

    [phase] defaults to [Startup]. [status], [request_id], and [redacted_body]
    carry provider transport context when available. [redacted_body] must
    already be safe to persist or display.

    Raises [Invalid_argument] if [message] is empty, [Other] has an invalid or
    reserved label, [status] is outside [100..599], or [request_id] or
    [redacted_body] is empty when present. *)

val kind : t -> kind
(** [kind t] is [t]'s provider-neutral class. *)

val phase : t -> phase
(** [phase t] is [t]'s failure phase. *)

val message : t -> string
(** [message t] is [t]'s human-readable diagnostic.

    The text is not a stable programmatic interface; branch on {!kind},
    {!phase}, and the structured fields instead. *)

val provider : t -> Provider.t option
(** [provider t] is the associated provider, if known. *)

val status : t -> int option
(** [status t] is the associated HTTP status code, if any. *)

val request_id : t -> string option
(** [request_id t] is the provider request id, if any. *)

val redacted_body : t -> string option
(** [redacted_body t] is a log-safe provider body, if any. *)

val label : kind -> string
(** [label kind] is [kind]'s stable lowercase label. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same payload. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps errors to JSON objects.

    Decoding errors if the object violates {!make}. *)
