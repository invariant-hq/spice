(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Non-empty process argv values.

    [Argv.t] is a spawn-boundary value, not a permission fact. Permission review
    records command intent with [Spice_permission.Access.Command]. *)

type t
(** A non-empty process argv. *)

val make : program:string -> string list -> t
(** [make ~program args] is a process invocation.

    Raises [Invalid_argument] if [program] is empty. *)

val program : t -> string
(** [program t] is the executable name or path. *)

val args : t -> string list
(** [args t] are the arguments after {!program}. *)

val to_list : t -> string list
(** [to_list t] is the executable followed by its arguments. *)
