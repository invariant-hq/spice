(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Permission requests over trusted access facts.

    A request groups one or more {!Access.t} values into one permission review.
    Tools and host subsystems produce requests before attempting an operation;
    policies decide whether the grouped accesses may proceed, need reviewer
    input, or are denied.

    Requests are inert data. They contain source metadata and item metadata for
    routing, display, and audit, but no prompt ids, continuations, callbacks,
    waiters, reviewer replies, or UI rendering. Runtime prompt correlation
    belongs to the host value that represents a pending prompt.

    Construct the trusted operation facts with {!Access}, attach display and
    change metadata with {!Item.make} when needed, group them with {!make}, then
    pass the request to {!Policy.decide}. Policy evaluation uses
    {!normalized_accesses}; the original item list and order remain available
    for host diagnostics and durable records.

    Constructors raise [Invalid_argument] when their arguments cannot satisfy
    the documented invariants. The JSON codec reports the same invalid states as
    decode errors. *)

(** {1:requests Requests} *)

type t
(** The type for permission requests.

    Invariant: [accesses] is non-empty and [source] is non-empty when present.
    Items are non-empty and item display is non-empty when present.

    [source] is the tool or subsystem that produced the request. It is
    provenance metadata for routing, display, and audit; it does not affect
    permission semantics. Item display and change metadata are the same category
    of fact; see {!Item} and {!Change}. *)

(** {1:changes Changes} *)

module Change : sig
  (** Planned-change metadata for reviewed accesses.

      Change metadata is display and audit metadata, like {!val:source}: it
      travels with the request and its durable records, but it has no permission
      semantics. It does not affect policy decisions, stable access facts,
      runtime grants, or rule matching.

      Change content must originate from the decoded tool input the host is
      asking to run -- never from filesystem reads -- so producing it cannot
      disclose file content the model has not already supplied, and recomputing
      it from the same decoded input is deterministic. *)

  type t
  (** The type for one planned content change.

      [diff] is a rendered change and may be size-capped by the producer. Counts
      are present only when exact. *)

  val make : ?diff:string -> ?additions:int -> ?removals:int -> unit -> t
  (** [make ?diff ?additions ?removals ()] is planned-change metadata.

      A count is supplied only when it is exact and must be non-negative; a
      producer that cannot know a count omits it. [diff] must be non-empty when
      present. At least one field must be present.

      Raises [Invalid_argument] when these invariants are violated. *)

  val diff : t -> string option
  (** [diff t] is [t]'s rendered change text, if any. *)

  val additions : t -> int option
  (** [additions t] is [t]'s exact added-line count, if known. *)

  val removals : t -> int option
  (** [removals t] is [t]'s exact removed-line count, if known. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same change metadata. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a change for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps changes to JSON objects. *)
end

(** {1:items Request items} *)

module Item : sig
  (** One requested access with display and audit metadata.

      [access] is the stable permission identity. [display] and [change] are
      request-local metadata and do not affect policy decisions, runtime grants,
      or rule matching. *)

  type t
  (** The type for one requested access item.

      Invariant: [display] is non-empty when present. *)

  val make : ?display:string -> ?change:Change.t -> Access.t -> t
  (** [make ?display ?change access] is one requested [access].

      [display] is optional UI/audit text for this request occurrence. Use it
      for path text or other human-facing labels that are not part of the
      permission identity.

      Raises [Invalid_argument] if [display] is empty when present. *)

  val access : t -> Access.t
  (** [access item] is the stable permission identity. *)

  val display : t -> string option
  (** [display item] is optional request-local display text. *)

  val change : t -> Change.t option
  (** [change item] is optional planned-change metadata. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same item data. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an item for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps request items to JSON objects. *)
end

(** {1:constructing Constructing requests} *)

val make : ?source:string -> ?grantable:bool -> Item.t list -> t
(** [make ?source ?grantable items] is a permission request for [items].

    The item order is significant for policy diagnostics: when several accesses
    are denied, policy evaluation reports the first denied access in this order.

    [grantable] (default [true]) controls whether a session-scope approval
    persists the request's accesses as grants; [false] caps approval at a single
    use, so a [Session] allow grants nothing and every later request reviews
    afresh. See {!grantable}.

    Raises [Invalid_argument] if [items] is empty or if [source] is empty when
    present. *)

val of_accesses : ?source:string -> ?grantable:bool -> Access.t list -> t
(** [of_accesses ?source ?grantable accesses] is a permission request for
    [accesses].

    The access list order is significant for policy diagnostics: when several
    accesses are denied, policy evaluation reports the first denied access in
    this order.

    [grantable] behaves as in {!make}.

    Raises [Invalid_argument] if [accesses] is empty, if [source] is empty when
    present. *)

(** {1:inspecting Inspecting requests} *)

val source : t -> string option
(** [source r] is the tool or subsystem that produced [r], if any.

    This is routing, display, and audit metadata. It does not affect permission
    matching. *)

val grantable : t -> bool
(** [grantable r] is [false] when a session-scope approval of [r] must not
    persist any grant — the approval authorizes a single use and every later
    request is reviewed again — and [true] (the default) otherwise.

    Unlike {!source}, this does affect resolution semantics: it gates whether
    {!Policy.Review.grant} adds the reviewed accesses to the session grants. *)

val accesses : t -> Access.t list
(** [accesses r] is [r]'s non-empty original access list, in caller order. *)

val items : t -> Item.t list
(** [items r] is [r]'s non-empty original item list, in caller order. *)

val items_for_access : t -> Access.t -> Item.t list
(** [items_for_access r access] is every item in [r] whose stable access
    identity is [access], in original request item order. *)

val changes_for_access : t -> Access.t -> Change.t list
(** [changes_for_access r access] is the planned-change metadata attached to
    {!items_for_access}, omitting items without change metadata. *)

val normalized_accesses : t -> Access.t list
(** [normalized_accesses r] is [accesses r] with exact duplicate access facts
    removed, preserving the first occurrence of each access.

    Metadata-only item differences do not affect this result. *)

val unique_accesses : t -> Access.Set.t
(** [unique_accesses r] is the set of stable access identities in [r].

    This collapses exact duplicates. Use {!items} for diagnostics that need
    request-local display or evidence. *)

(** {1:predicates Predicates and comparisons} *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] contain the same request data.

    Item metadata and [source] participate in equality. *)

(** {1:fmt Formatting} *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a request for diagnostics. The output is not stable storage
    syntax. *)

(** {1:json JSON} *)

val jsont : t Jsont.t
(** [jsont] maps requests to versioned JSON objects.

    Unknown object members and constructor-invalid request states are decoding
    errors. *)
