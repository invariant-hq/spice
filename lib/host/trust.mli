(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace trust store.

    User-scoped host state recording granted workspace roots. The store is a
    dormant seam: workspace config already loads safe-by-construction (see
    {!Config.load}), so nothing consults trust today. It is recorded for a
    future trust-gated feature and is never stored in the workspace. *)

module Error : sig
  type t
  (** The type for recoverable trust-store errors, such as reading or writing
      the user trust store. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic, intended for users and tests
      rather than stable storage. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e]'s message for diagnostics. *)
end

type t
(** Snapshot of trusted workspace roots. *)

val load :
  stdenv:Eio_unix.Stdenv.base ->
  ?process_env:Env.t ->
  unit ->
  (t, Error.t) result
(** [load ~stdenv ()] reads the granted workspace roots from the user trust
    store. *)

val grant :
  stdenv:Eio_unix.Stdenv.base ->
  t ->
  workspace:string ->
  (string, Error.t) result
(** [grant ~stdenv t ~workspace] records [workspace] in the user trust store and
    returns the canonical path it recorded. Granting an already-trusted
    workspace does not rewrite the store. *)

val revoke :
  stdenv:Eio_unix.Stdenv.base ->
  t ->
  workspace:string ->
  (string, Error.t) result
(** [revoke ~stdenv t ~workspace] removes [workspace] from the user trust store
    and returns the canonical path it removed. Revoking an untrusted workspace
    does not rewrite the store. *)
