(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session document metadata.

    Metadata is saved with a {!Spice_session.t} document, but it does not replay
    into {!State.t}. It records session-level facts needed to save, load, list,
    and fork sessions without making them model-visible semantic events.

    Updating metadata does not append session events and does not change the
    reconstructed transcript. Hosts are responsible for touching [updated_at]
    when their persistence workflow wants a metadata update to move the saved
    modification time. *)

module Status : sig
  (** Durable session lifecycle status. *)

  type t =
    | Active  (** The session can accept new semantic events. *)
    | Archived
        (** The session is hidden from ordinary active lists and cannot accept
            new semantic events until restored. *)
    | Deleted
        (** The session is tombstoned. Deleted sessions cannot be restored,
            archived, appended to, or forked. *)

  val is_active : t -> bool
  (** [is_active t] is [true] iff [t] is {!Active}. *)

  val is_archived : t -> bool
  (** [is_archived t] is [true] iff [t] is {!Archived}. *)

  val is_deleted : t -> bool
  (** [is_deleted t] is [true] iff [t] is {!Deleted}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same status. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a status for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps statuses to JSON values and rejects unknown status tags. *)
end

module Forked_from : sig
  (** Durable fork lineage.

      [copied_events] is the number of parent semantic events copied into the
      child document. It is a prefix length, not a store cursor. *)

  type t = private { parent : Id.t; copied_events : int }

  val make : parent:Id.t -> copied_events:int -> t
  (** [make ~parent ~copied_events] is fork lineage.

      Raises [Invalid_argument] if [copied_events] is negative. *)

  val parent : t -> Id.t
  (** [parent t] is [t]'s parent session id. *)

  val copied_events : t -> int
  (** [copied_events t] is [t]'s copied parent event count. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same lineage. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats fork lineage for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps fork lineage to JSON values. Decoding validates the same
      non-negative [copied_events] invariant as {!make}. *)
end

type t = private {
  title : string option;  (** Optional non-empty user-facing title. *)
  status : Status.t;  (** Saved lifecycle status. *)
  forked_from : Forked_from.t option;
      (** Fork lineage, if this document was created from another session. *)
  cwd : Spice_path.Abs.t;  (** Creating workspace root. *)
  created_at : Time.t;  (** Saved creation time. *)
  updated_at : Time.t;  (** Saved last update time. *)
}
(** The type for durable session metadata.

    [updated_at] is always greater than or equal to [created_at]. *)

val make :
  ?title:string ->
  ?status:Status.t ->
  ?forked_from:Forked_from.t ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  updated_at:Time.t ->
  unit ->
  t
(** [make ?title ?status ?forked_from ~cwd ~created_at ~updated_at ()] is
    metadata.

    [status] defaults to {!Status.Active}. [title], when present, must be a
    non-empty display title; no trimming or normalization is performed.

    Raises [Invalid_argument] if [title] is empty or [updated_at] is before
    [created_at]. *)

val title : t -> string option
(** [title t] is [t]'s optional user-facing title. *)

val status : t -> Status.t
(** [status t] is [t]'s saved lifecycle status. *)

val fork : t -> Forked_from.t option
(** [fork t] is [t]'s fork lineage, if it was forked from another session. *)

val cwd : t -> Spice_path.Abs.t
(** [cwd t] is [t]'s creating workspace root. *)

val created_at : t -> Time.t
(** [created_at t] is [t]'s saved creation time. *)

val updated_at : t -> Time.t
(** [updated_at t] is [t]'s saved last update time. *)

val with_title : string option -> t -> t
(** [with_title title t] is [t] with title [title].

    Raises [Invalid_argument] if [title] is [Some ""]. *)

val with_status : Status.t -> t -> t
(** [with_status status t] is [t] with status [status]. *)

val with_fork : Forked_from.t option -> t -> t
(** [with_fork fork t] is [t] with fork lineage [fork]. *)

val touch : Time.t -> t -> t
(** [touch time t] is [t] with [updated_at] set to [time].

    Raises [Invalid_argument] if [time] is before [created_at t]. *)

val is_active : t -> bool
(** [is_active t] is [true] iff [status t] is {!Status.Active}. *)

val is_archived : t -> bool
(** [is_archived t] is [true] iff [status t] is {!Status.Archived}. *)

val is_deleted : t -> bool
(** [is_deleted t] is [true] iff [status t] is {!Status.Deleted}. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same metadata. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats metadata for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps metadata to JSON values. Decoding validates title and timestamp
    ordering invariants. *)
