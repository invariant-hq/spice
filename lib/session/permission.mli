(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session permission facts.

    A session permission request records that an accepted turn reached an
    authority boundary. It stores the blocked model tool call, the original
    permission request, and the stable asked accesses needed to reconstruct a
    {!Spice_permission.Policy.Review.t} during replay.

    Permission values do not contain callbacks, waiters, UI prompts, live policy
    values, or grant caches. Runtime grants are reconstructed by applying stored
    answers to stored asked accesses. A denied permission also stores the
    model-visible tool result that answers the blocked call; without that result
    replay could not make the transcript ready again. *)

(** {1:ids Identifiers} *)

module Id : sig
  type t
  (** The type for stable permission prompt identifiers.

      Invariant: an identifier's stable textual form is non-empty. *)

  val of_string : string -> t
  (** [of_string s] is [s] as a permission prompt id.

      Raises [Invalid_argument] if [s] is empty. *)

  val to_string : t -> string
  (** [to_string id] is [id]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same permission prompt id.
  *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representations.

      The order is compatible with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an id for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps permission prompt ids to JSON strings. Decoding validates the
      same non-empty invariant as {!of_string}. *)
end

(** {1:requests Requests} *)

module Requested : sig
  (** Durable permission requests. *)

  type t
  (** The type for a durable permission request.

      Invariant: [asked] is non-empty and every access in [asked] belongs to
      [request]. State replay additionally requires [turn] to be the active
      unfinished turn and [tool_call] to be pending in the transcript. *)

  val make :
    id:Id.t ->
    turn:Turn.Id.t ->
    tool_call:Spice_llm.Tool.Call.t ->
    request:Spice_permission.Request.t ->
    asked:Spice_permission.Access.Set.t ->
    unit ->
    t
  (** [make ~id ~turn ~tool_call ~request ~asked ()] is a durable permission
      request.

      Raises [Invalid_argument] if [asked] is empty or contains an access not
      present in [request]. *)

  val of_review :
    id:Id.t ->
    turn:Turn.Id.t ->
    tool_call:Spice_llm.Tool.Call.t ->
    Spice_permission.Policy.Review.t ->
    t
  (** [of_review ~id ~turn ~tool_call review] is a durable permission request
      for [review] blocking [tool_call]. *)

  val id : t -> Id.t
  (** [id r] is [r]'s permission prompt id. *)

  val turn : t -> Turn.Id.t
  (** [turn r] is the turn blocked by [r]. *)

  val tool_call : t -> Spice_llm.Tool.Call.t
  (** [tool_call r] is the model tool call blocked by [r]. *)

  val request : t -> Spice_permission.Request.t
  (** [request r] is [r]'s original permission request. *)

  val asked : t -> Spice_permission.Access.Set.t
  (** [asked r] is the non-empty set of accesses covered by the reviewer answer.
  *)

  val review : t -> Spice_permission.Policy.Review.t
  (** [review r] reconstructs the policy review represented by [r] from the
      stored request and asked-access set. It does not re-run host policy. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same request data. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a permission request for diagnostics. The output is not
      stable storage syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps permission requests to JSON values. Decoding validates the
      asked-access invariant and requires the blocked [tool_call] field. *)
end

(** {1:replies Replies} *)

module Resolved : sig
  (** Durable permission answers. *)

  type t
  (** The type for a durable permission answer. *)

  type via = [ `Reviewer | `Unattended ]
  (** The type for resolution provenance.

      [`Reviewer] is a decision made by a user. [`Unattended] is an automatic
      denial recorded by an unattended host policy; it never applies to allow
      replies. Provenance is audit data and does not affect state replay. *)

  val allow_once : id:Id.t -> t
  (** [allow_once ~id] is a durable one-shot allow answer to permission prompt
      [id]. *)

  val allow_session : id:Id.t -> t
  (** [allow_session ~id] is a durable session allow answer to permission prompt
      [id]. During state replay it updates reconstructed runtime grants for the
      asked accesses on the matching request. *)

  val deny : id:Id.t -> ?via:via -> Spice_llm.Tool.Result.t -> t
  (** [deny ~id ?via result] is a durable deny answer to permission prompt [id].

      [result] is the model-visible tool result that consumes the blocked tool
      call during replay. State replay requires [result] to answer the exact
      call id and name stored on the matching request. [via] defaults to
      [`Reviewer]; hosts that auto-deny reviews in unattended runs record
      [`Unattended] so audit output never conflates the two. *)

  val id : t -> Id.t
  (** [id r] is the prompt id [r] resolves. *)

  (** The type for a resolved permission's outcome. Only denials carry a result,
      so the legal answer/result pairings hold by construction. *)
  type decision =
    | Allow of Spice_permission.Policy.Review.scope
        (** The blocked call is granted with this scope. *)
    | Deny of Spice_llm.Tool.Result.t
        (** The model-visible tool result that consumes the blocked call during
            replay. *)

  val decision : t -> decision
  (** [decision r] is [Allow scope] if [r] permits the blocked call with [scope]
      and [Deny result] if it refuses the call and answers it with [result]. *)

  val via : t -> via
  (** [via r] is [r]'s resolution provenance. Allow answers are always
      [`Reviewer]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same answer data. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a permission answer for diagnostics. The output is not stable
      storage syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps permission answers to JSON values. Decoding requires deny
      answers to include [tool_result] and allow answers to omit it. *)
end

(** {1:predicates Predicates and formatters} *)

val matches : Requested.t -> Resolved.t -> bool
(** [matches request resolution] is [true] iff [resolution] answers [request].
*)
