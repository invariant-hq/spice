(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Provider model identities.

    A model records the provider namespace, provider-local API family, and
    provider-native model id used for one model request. It is an identity, not
    a catalog entry, capability table, price record, credential, endpoint, or
    provider option bundle. Provider clients use these identities to decide
    whether a request is accepted. *)

module Api : sig
  type t
  (** The type for provider-local API families.

      API families distinguish incompatible request and replay protocols within
      one provider namespace, for example chat-style and responses-style APIs.
  *)

  val make : string -> t
  (** [make id] is API family [id].

      API identifiers are lowercase ASCII component names separated by ['.'].
      Each component starts with a lowercase letter and then contains lowercase
      letters, digits, or ['-'].

      Raises [Invalid_argument] if [id] is invalid. *)

  val id : t -> string
  (** [id t] is [t]'s identifier. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same identifier. *)

  val compare : t -> t -> int
  (** [compare a b] orders APIs by identifier. The order is compatible with
      {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps APIs to JSON strings.

      Decoding errors if the string is not an API identifier. *)
end

type t
(** The type for model identities. *)

val make : provider:Provider.t -> api:Api.t -> id:string -> t
(** [make ~provider ~api ~id] is model [id] interpreted by [provider]'s [api].

    [id] is the provider-native model id and must be non-empty. The id is not
    parsed or normalized by [spice.llm].

    Raises [Invalid_argument] if [id] is empty. *)

val provider : t -> Provider.t
(** [provider t] is [t]'s provider namespace. *)

val api : t -> Api.t
(** [api t] is [t]'s provider-local request/replay API. *)

val id : t -> string
(** [id t] is [t]'s provider-native model id. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same provider, API, and model
    id. *)

val compare : t -> t -> int
(** [compare a b] orders models by provider, API, then id. The order is
    compatible with {!equal}. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps models to JSON objects.

    Decoding errors if the object does not satisfy {!make}. *)
