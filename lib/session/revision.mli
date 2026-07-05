(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Optimistic-concurrency revision tokens.

    A revision is an opaque stale-write token identifying the exact encoded
    bytes of one persisted session document. It is a compare-and-set
    precondition only: it is not semantic session state, not a timestamp, not an
    ordered version number, and not a checkpoint id.

    A durable store is the normal producer, minting a revision from a document's
    encoded bytes and returning it beside the saved session; a later write
    supplies it back so the store can reject a lost update. This module carries
    that token through the pure session protocol without defining a store.
    Revisions are compared by value. *)

type t
(** The type for a stale-write token identifying one persisted document
    revision. *)

val of_string : string -> t
(** [of_string s] is [s] as a revision token.

    A store produces revisions from a document's encoded bytes; this constructor
    wraps an already-minted token string so pure projections and tests can carry
    a revision without a store. It does not validate that [s] was minted by any
    store. *)

val to_string : t -> string
(** [to_string t] is [t]'s token string. It is suitable for diagnostics and for
    carrying the token through non-typed surfaces. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same revision, compared by
    token value. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. The output is not stable storage
    syntax. *)
