(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session identifiers.

    Session ids are caller-supplied stable strings used to name durable session
    documents. This module validates only the local identifier shape; store
    uniqueness and path mapping belong to the session store. *)

type t
(** The type for stable session identifiers.

    Invariant: an identifier's stable textual form is non-empty. *)

val of_string : string -> t
(** [of_string s] is [s] as a session id.

    Raises [Invalid_argument] if [s] is empty. *)

val to_string : t -> string
(** [to_string id] is [id]'s stable string representation. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same session id. *)

val compare : t -> t -> int
(** [compare a b] orders ids by their stable string representations.

    The order is compatible with {!equal}. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats an id for diagnostics. The output is not stable storage syntax.
*)

val jsont : t Jsont.t
(** [jsont] maps session ids to JSON strings. Decoding validates the same
    non-empty invariant as {!of_string}. *)
