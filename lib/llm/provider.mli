(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Provider namespaces.

    A provider is a stable owner namespace for model APIs, model ids, and
    provider-owned continuity data. It is not a client, credential, endpoint,
    catalog, or transport handle. Use {!Client.t} for effectful interpreters
    that know how to contact a provider. *)

type t
(** The type for provider namespaces.

    Provider identifiers are lowercase ASCII slugs. They start with a lowercase
    letter and then contain lowercase letters, digits, or ['-']. *)

val make : string -> t
(** [make id] is provider namespace [id].

    Raises [Invalid_argument] if [id] is not a provider identifier. *)

val id : t -> string
(** [id t] is [t]'s stable textual identifier.

    The returned string satisfies the provider identifier grammar accepted by
    {!make}. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same identifier. *)

val compare : t -> t -> int
(** [compare a b] orders providers by identifier. The order is compatible with
    {!equal}. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t]'s identifier on [ppf]. *)

val jsont : t Jsont.t
(** [jsont] maps providers to JSON strings.

    Decoding errors if the string is not a provider identifier. *)
