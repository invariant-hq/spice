(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace path resolution errors.

    A resolution error is the failure to place an external address inside the
    workspace. It is returned by {!Spice_workspace.resolve_string} and
    {!Spice_workspace.import_abs}, and is distinct from the configuration and
    membership failures reported by {!Spice_workspace.Error}.

    These errors are pure address-model failures. They do not report filesystem
    observation failures such as missing files, permission errors,
    non-directories, invalid UTF-8, symlink escapes, or size limits; those
    belong to the host observation layer. *)

type t =
  | Outside_workspace of Spice_path.Abs.t
      (** [Outside_workspace path] means absolute [path] is not lexically under
          any workspace root. *)
  | Invalid_input of Spice_path.Error.t
      (** [Invalid_input error] means raw path syntax failed before workspace
          resolution could produce a workspace path. *)

val message : t -> string
(** [message error] is a human-readable diagnostic for [error].

    [message] is for display, not programmatic matching. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same resolution error. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf error] formats [error] for diagnostics. *)
