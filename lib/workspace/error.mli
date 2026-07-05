(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace construction and membership errors.

    Errors are structured so callers can distinguish bad workspace configuration
    from a root or path that is not admitted by the workspace. Match on
    {!type:t} for recovery. {!message} and {!pp} are diagnostics.

    These are configuration and membership failures, not per-path resolution.
    Failures to place an external address inside the workspace are reported by
    {!Resolve_error}.

    These errors are pure address-model failures. They do not report filesystem
    observation failures such as missing files, permission errors,
    non-directories, invalid UTF-8, symlink escapes, or size limits; those
    belong to the host observation layer. *)

type t =
  | Empty_roots
      (** [Empty_roots] means a workspace was requested without any roots. *)
  | Conflicting_root of { existing : Root.t; duplicate : Root.t }
      (** [Conflicting_root { existing; duplicate }] means two roots use the
          same stable key for different logical directories or the same logical
          directory with different stable keys.

          The [existing] root is the first admitted root that conflicts with
          [duplicate]. *)
  | Root_not_in_workspace of Root.t
      (** [Root_not_in_workspace root] means a path or current directory belongs
          to [root], but no equal root is admitted by the workspace. *)

val message : t -> string
(** [message error] is a human-readable diagnostic for [error].

    [message] is for display, not programmatic matching. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same workspace error. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf error] formats [error] for diagnostics. *)
