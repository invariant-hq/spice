(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Product permission policy.

    Workflow contracts decide which operations are possible. This module owns
    only the per-run handling of review outcomes, unattended behavior, rule
    identity, and the provenance-carrying policy table. *)

module Review_behavior : sig
  (** What a run does with accesses whose policy outcome is review. *)

  type t = Default | Bypass

  val all : t list
  (** [all] lists the per-run behaviors in declaration order. *)

  val of_string : string -> t option
  (** [of_string s] parses [default] or [bypass]. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable command-line spelling. *)

  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit

  val on_review : t -> Spice_permission.Policy.on_review
  (** [on_review t] maps [Default] to policy review and [Bypass] to allowing
      review outcomes. Denials are never bypassed. *)
end

module Unattended : sig
  (** What a headless run does when a permission review is needed. *)

  type t = Block | Deny

  val all : t list
  val of_string : string -> t option
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

val rule_id : Spice_permission.Policy.Rule.t -> string
(** [rule_id rule] is [rule]'s content-derived product identity. *)

val web_docs_allowlist : string list
(** [web_docs_allowlist] is the curated set of documentation hosts that the
    product policy allows in-process web readers to fetch without review. *)

module Run : sig
  (** The permission behavior and rule table for one model/tool run. *)

  type 'src t

  type 'src row = private {
    id : string;
    source : 'src;
    rule : Spice_permission.Policy.Rule.t;
  }

  val make :
    review:Review_behavior.t ->
    product:'src ->
    durable:('src * Spice_permission.Policy.Rule.t list) list ->
    unit ->
    'src t
  (** [make ~review ~product ~durable ()] constructs the complete run table.
      Durable configured rules evaluate first. Conversation rules supplied to
      {!policy} follow. Fixed product rules then keep high-impact commands
      reviewable before allowing commands confined to project reads with
      restricted networking, commands behind an explicit external boundary,
      native workspace operations, and curated in-process documentation reads.
      [product] is the provenance attached to those fixed rules.

      Raises [Invalid_argument] if one durable layer contains the same rule
      more than once. *)

  val review_behavior : 'src t -> Review_behavior.t
  (** [review_behavior t] is the per-run handling of review outcomes. *)

  val on_review : 'src t -> Spice_permission.Policy.on_review
  (** [on_review t] maps {!Review_behavior.Default} to policy review and
      {!Review_behavior.Bypass} to allowing review outcomes. Denials are never
      bypassed. *)

  val rows : 'src t -> 'src row list
  (** [rows t] are the durable and fixed product rules in evaluation order. *)

  val find : 'src t -> Spice_permission.Policy.Rule.t -> 'src row option

  val policy :
    conversation:Spice_permission.Policy.Rule.t list ->
    'src t ->
    Spice_permission.Policy.t
  (** [policy ~conversation t] constructs the ordered pure policy for the
      current conversation. *)

  val denial_message :
    source:('src -> string) ->
    'src t ->
    Spice_permission.Policy.Denial.t ->
    string
end
