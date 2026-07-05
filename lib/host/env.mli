(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Process environment snapshots.

    Host services share one immutable view of the process environment so
    configuration, account, catalog, and trust resolution all read the same
    bindings. Configuration loading records its snapshot; other services should
    reuse that snapshot rather than re-reading the process environment. *)

type t
(** The type for immutable process environment snapshots. *)

val empty : t
(** [empty] has no bindings. *)

val of_list : (string * string) list -> t
(** [of_list bindings] contains [bindings]. Later bindings for the same name
    replace earlier bindings. *)

val current : unit -> t
(** [current ()] is a snapshot of the current process environment. Later
    process-environment changes do not affect the returned value. Bindings
    without [=] are ignored. *)

val get : t -> string -> string option
(** [get t name] is the value of [name] in [t], if any. *)

val to_list : t -> (string * string) list
(** [to_list t] is the list of bindings in [t], ordered by variable name. *)
