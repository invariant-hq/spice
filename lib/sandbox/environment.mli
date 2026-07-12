(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Exact environments for sandboxed commands.

    An environment is constructed once when the host resolves a sandbox and is
    then carried by every execution route. It contains only host-derived
    scratch bindings, a validated executable path, a fixed allow-list of
    locale, terminal, and OCaml toolchain variables, and explicitly requested
    user variables. Values are never rendered by this module. *)

module Error : sig
  type name_reason = Empty | Contains_nul | Contains_equals
  type path_reason = Missing | Empty_segment | Relative_segment | Malformed_segment

  type t =
    | Invalid_name of { name : string; reason : name_reason }
    | Duplicate_name of string
    | Reserved_name of string
    | Invalid_value of { name : string }
    | Invalid_path of { name : string; index : int option; reason : path_reason }

  val message : t -> string
  (** [message error] explains the invalid input without including an
      environment value. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf error] formats {!message}[ error]. *)

  val equal : t -> t -> bool
end

type t
(** An exact, validated process environment. *)

val make :
  path:string ->
  scratch:Spice_path.Abs.t ->
  user_names:string list ->
  launch:(string -> string option) ->
  (t, Error.t) result
(** [make ~path ~scratch ~user_names ~launch] constructs an exact environment.

    [path] must be a non-empty colon-separated list of absolute paths. Empty,
    relative, and malformed entries are rejected instead of being interpreted
    relative to a child process's current directory.

    [HOME], [TMPDIR], [TMP], and [TEMP] are derived from [scratch]. Pager and
    color variables receive deterministic non-interactive values. A fixed set
    of locale and OCaml toolchain variables may be copied from [launch] after
    validation; missing or malformed optional inherited bindings are omitted.
    [user_names] adds explicit names to that allow-list; duplicate, reserved,
    malformed, and NUL-containing inputs are rejected. *)

val bindings : t -> (string * string) list
(** [bindings t] is the complete environment to pass to a child process. *)

val names : t -> string list
(** [names t] are the admitted variable names in canonical order. *)

val scratch : t -> Spice_path.Abs.t
(** [scratch t] is the private directory used for home and temporary files. *)

val equal : t -> t -> bool
val pp_names : Format.formatter -> t -> unit
(** [pp_names ppf t] formats only variable names, never values. *)
