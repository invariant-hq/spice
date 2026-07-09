(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Ephemeral host notices for model-request injection.

    Notices are model-visible facts produced outside the durable session
    transcript: filesystem watcher batches, Dune diagnostic changes, code-review
    comments, or other host integrations. They are not session events and are
    not persisted. A host queues them and, immediately before an ordinary model
    request, drains the queue and appends the drained notices to the request
    prelude as developer messages ({!to_message}).

    This module is the notice datum. The engine owns the capacity-bounded,
    fiber-safe queue that batches notices for injection. *)

(** {1:types Types} *)

module Severity : sig
  (** The type for model-facing notice severity. *)
  type t = Info | Warning | Error

  val to_string : t -> string
  (** [to_string severity] is ["info"], ["warning"], or ["error"]. *)

  val compare : t -> t -> int
  (** [compare a b] orders severities by constructor order. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same severity. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf severity] formats [severity] for diagnostics. *)
end

type t
(** The type for a pending host notice.

    [source] names the producer. [key] identifies the fact being reported and is
    the queue coalescing key: a newer queued notice with the same key replaces
    the older queued notice. The key is not model-visible text; it is
    producer-owned state identity for retries, reconnect loops, and duplicate
    event suppression. *)

val make :
  source:string ->
  severity:Severity.t ->
  title:string ->
  ?body:string ->
  key:string ->
  unit ->
  t
(** [make ~source ~severity ~title ?body ~key ()] is a notice.

    [source], [title], and an optional [body] are model-visible text. A
    title-only notice is rendered without a blank body separator. [key] must be
    stable for the underlying fact while that fact remains logically unchanged,
    and must change when a queued fact should be surfaced as a distinct pending
    notice.

    Raises [Invalid_argument] if [source], [title], [key], or a supplied [body]
    is empty. *)

val source : t -> string
(** [source t] is the producer that emitted [t]. *)

val severity : t -> Severity.t
(** [severity t] is [t]'s model-facing severity. *)

val title : t -> string
(** [title t] is [t]'s short model-visible title. *)

val body : t -> string option
(** [body t] is [t]'s optional model-visible body. *)

val key : t -> string
(** [key t] is [t]'s queue coalescing key. *)

val to_message : t -> Spice_llm.Message.t
(** [to_message t] renders [t] as a developer message suitable for request
    prelude injection.

    The rendered message is prompt context, not durable session state. Its text
    shape is intended for model consumption and diagnostics, not for stable
    programmatic parsing. The message is authoritative only as host context; the
    model should use tools for fresh filesystem, Dune, or review data when it
    needs exact evidence. *)
