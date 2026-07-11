(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Persistent workspace trust decisions.

    A value resolves one canonical workspace root to its current trust status.
    Trust controls ambient project customization; it does not grant permission
    or operating-system authority. Decisions live in the user configuration
    home and never in the workspace. *)

type status = Unknown | Untrusted | Trusted
(** The trust status of a workspace root. [Unknown] is never persisted. *)

type t
(** Trust status for one canonical workspace root. *)

module Error : sig
  type t
  (** A recoverable user-directory, root-validation, store-read, decode, lock,
      or write error. *)

  val message : t -> string
  (** [message e] is an actionable human-readable diagnostic. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [message e]. *)
end

val find :
  stdenv:Eio_unix.Stdenv.base ->
  ?process_env:Env.t ->
  root:Spice_path.Abs.t ->
  unit ->
  (t, Error.t) result
(** [find ~stdenv ~root ()] is the stored decision for [root], or [Unknown]
    when none exists. [root] is canonicalized with [realpath] and must be a
    directory. Store read or decode failures return [Error]. *)

val trust :
  stdenv:Eio_unix.Stdenv.base ->
  ?process_env:Env.t ->
  root:Spice_path.Abs.t ->
  unit ->
  (t, Error.t) result
(** [trust ~stdenv ~root ()] persists [Trusted] for [root] and returns the
    canonical resolution. Concurrent updates are serialized and re-read the
    latest store before replacement. Replacement flushes the new file and its
    containing directory on filesystems that support directory [fsync]. *)

val untrust :
  stdenv:Eio_unix.Stdenv.base ->
  ?process_env:Env.t ->
  root:Spice_path.Abs.t ->
  unit ->
  (t, Error.t) result
(** [untrust ~stdenv ~root ()] persists [Untrusted] for [root] and returns the
    canonical resolution. It does not remove the decision and uses the same
    durable replacement protocol as {!trust}. *)

val is_trusted : t -> bool
(** [is_trusted t] is [true] iff {!status}[ t] is [Trusted]. *)

val root : t -> Spice_path.Abs.t
(** [root t] is the canonical workspace root described by [t]. *)

val status : t -> status
(** [status t] is [t]'s resolved decision. *)

val status_to_string : status -> string
(** [status_to_string status] is ["unknown"], ["untrusted"], or ["trusted"]. *)
