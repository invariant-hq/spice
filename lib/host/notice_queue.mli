(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Capacity-bounded, fiber-safe queues of pending host notices.

    A host produces {{!Spice_protocol.Notice.t} notices} — model-visible facts
    from outside the durable transcript (filesystem watcher batches, Dune
    diagnostic changes, code-review comments) — and enqueues them here.
    Immediately before an ordinary model request, request preparation drains the
    queue as a {!batch}, appends the drained notices to the request prelude as
    developer messages ({!Spice_protocol.Notice.to_message}), and then commits
    the batch once the response is accepted or rolls it back to retry the same
    notices. Notices are ephemeral: they are neither session events nor
    persisted.

    A queue coalesces by {!Spice_protocol.Notice.key}: publishing a notice
    evicts any queued notice reporting the same fact, so a producer that emits
    on every retry or reconnect never floods the prelude with stale duplicates.

    This module is the queue half of host notices; the notice datum itself lives
    in {!module:Spice_protocol.Notice}. *)

(** {1:types Types} *)

type notice := Spice_protocol.Notice.t

type t
(** The type for pending notice queues.

    A queue is mutable and safe for concurrent producers. It retains at most its
    capacity of notices; taking a {!batch} consumes the queue's current contents
    until that batch is committed or rolled back. *)

type batch
(** The type for a drained batch of notices.

    A batch is the unit of request preparation: the notices removed from a queue
    by a single {!take}, held pending until {!commit} consumes them or
    {!rollback} returns them. Resolution is idempotent — a second {!commit} or
    {!rollback} on a resolved batch has no effect. *)

(** {1:constructors Constructors} *)

val create : ?capacity:int -> unit -> t
(** [create ?capacity ()] is an empty queue retaining at most [capacity] queued
    notices. [capacity] defaults to [32].

    Raises [Invalid_argument] if [capacity <= 0]. *)

(** {1:producing Producing} *)

val publish : t -> notice -> unit
(** [publish queue notice] queues [notice] as the newest retained notice.

    If a queued notice has the same {!Spice_protocol.Notice.key}, it is evicted
    first. If retaining [notice] would exceed the queue's capacity, the oldest
    retained notices are dropped. *)

(** {1:draining Draining} *)

val take : t -> batch
(** [take queue] empties [queue] and is its retained notices, oldest to newest,
    as a pending batch. *)

val notices : batch -> notice list
(** [notices batch] is the notices in [batch], oldest to newest. *)

val commit : batch -> unit
(** [commit batch] permanently consumes [batch]'s notices.

    Has no effect if [batch] was already committed or rolled back. *)

val rollback : batch -> unit
(** [rollback batch] returns [batch]'s notices to their queue.

    The restored notices keep their relative order and are older than any notice
    queued since the batch was taken. Key coalescing and capacity still apply: a
    restored notice is evicted by a newer queued notice with the same
    {!Spice_protocol.Notice.key}, and the oldest retained notices are dropped if
    capacity is exceeded.

    Has no effect if [batch] was already committed or rolled back. *)

(** {1:queries Queries} *)

val is_empty : t -> bool
(** [is_empty queue] is [true] iff [queue] currently retains no notices. *)
