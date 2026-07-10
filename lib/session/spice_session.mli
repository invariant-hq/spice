(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable sessions and pure replay state.

    [spice.session] defines the durable session value saved by the host and the
    semantic event language used to reconstruct a checked model-visible
    transcript. It does not define a store, scheduler, model client, executable
    tool runtime, or host session service.

    Construct sessions with {!create} or {!make} and inspect the reconstructed
    replay projection with {!state}. The sibling [spice.session.run] library
    plans ordinary active-turn mutations. Low-level import, repair, and replay
    tests can append raw semantic facts through {!Log}.

    Metadata changes and lifecycle changes are session updates, not semantic
    events. They do not modify {!state}, {!events}, or the model-visible
    transcript. *)

module Id = Id
(** Session identifiers. *)

module Time = Time
(** Durable session timestamps. *)

module Revision = Revision
(** Optimistic-concurrency revision tokens. *)

module Metadata = Metadata
(** Durable session metadata. *)

module Turn = Turn
(** Accepted model/tool loop facts. *)

module Permission = Permission
(** Durable permission request and reply facts. *)

module Tool_claim = Tool_claim
(** Durable executable tool claims. *)

module Compaction = Compaction
(** Durable model-replay compactions. *)

module Waiting = Waiting
(** Derived execution waiting boundaries. *)

module Event = Event
(** Durable session events. *)

module State = State
(** Pure reconstructed session state. *)

module Anchor = Anchor
(** Stable, replay-valid rewind positions. *)

(** {1:errors Errors} *)

module Error : sig
  (** Session operation errors. *)

  type t =
    | State of State.Error.t
        (** Semantic event replay failed while constructing or appending to the
            session. *)
    | Archived  (** The operation requires a non-archived session. *)
    | Deleted  (** The operation requires a non-deleted session. *)
    | Active_turn of Turn.Id.t
        (** The operation requires no active unfinished turn. *)
    | Unknown_turn of Turn.Id.t
        (** An anchor named a turn that is not present in the session. *)
    | Turn_not_finished of Turn.Id.t
        (** An {!Anchor.After} anchor named a turn with no terminal outcome. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The returned string is suitable for display and logs. Callers that need
      stable control flow should inspect [e] directly. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. The output is not stable storage
      syntax. *)
end

(** {1:sessions Sessions} *)

type t
(** The type for durable saved Spice sessions.

    A session contains its id, metadata, semantic event log, and a validated
    {!State.t} projection of that log. The projection is derived from the events
    and is validated whenever a session is decoded, reconstructed, or appended.

    The host owns where and how sessions are saved, including store uniqueness,
    revision checks, and timestamp policy. *)

type session = t
(** Alias for the session type, used in nested signatures whose own [t] would
    otherwise shadow the outer session type. *)

val create :
  id:Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  unit ->
  t
(** [create ~id ?title ~cwd ~created_at ()] is a new active session with no
    semantic events.

    [created_at] is used for both metadata creation and update time.

    Raises [Invalid_argument] if [title] is empty. *)

val make :
  id:Id.t -> metadata:Metadata.t -> events:Event.t list -> (t, Error.t) result
(** [make ~id ~metadata ~events] is a session reconstructed from saved parts.

    Returns [Error (State e)] if [events] do not form a valid semantic session
    replay. Metadata is not replayed; an archived or deleted session can still
    be reconstructed if its semantic events are valid. *)

val id : t -> Id.t
(** [id t] is [t]'s session id. *)

val metadata : t -> Metadata.t
(** [metadata t] is [t]'s durable session metadata. *)

val events : t -> Event.t list
(** [events t] is [t]'s semantic event log in application order. *)

val state : t -> State.t
(** [state t] is [t]'s validated semantic replay projection. *)

(** Machine-readable metrics projected from durable session events. *)
module Metrics : sig
  (** Machine-readable session spend and activity metrics. *)

  type t = private {
    usage : Spice_llm.Usage.t;
        (** Lane-wise sum of provider-reported response usage. Responses without
            usage contribute {!Spice_llm.Usage.zero}. *)
    responses : int;  (** Number of completed provider responses. *)
    turns : int;  (** Number of terminal turn events. *)
    tool_calls : int;  (** Number of finished executable tool calls. *)
    tool_failures : int;
        (** Number of finished executable tool calls marked as errors. *)
    tool_rejections : int;
        (** Number of model tool calls answered with an error result without
            being executed. Denied permission replies are counted by
            [permission_denials], not here. *)
    tool_calls_by_name : (string * int) list;
        (** Finished executable tool-call counts by model-visible tool name,
            sorted by name. *)
    permission_denials : int;  (** Number of denied permission replies. *)
  }
  (** The type for cumulative session metrics. Counts are non-negative. *)

  val of_events : Event.t list -> t
  (** [of_events events] is the low-level cumulative metrics projection of an
      already-validated event log.

      Raises [Invalid_argument] if an integer lane overflows. *)

  val of_session : session -> t
  (** [of_session session] is the cumulative metrics projection of [session]'s
      validated event log.

      Raises [Invalid_argument] if an integer lane overflows. *)

  val empty : t
  (** [empty] is the zero metrics value. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same metrics. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats metrics for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps metrics to JSON objects. *)
end

val set_title : string option -> t -> t
(** [set_title title t] is [t] with title [title].

    This does not change [updated_at].

    Raises [Invalid_argument] if [title] is [Some ""]. *)

val touch : Time.t -> t -> t
(** [touch time t] is [t] with its saved metadata update time set to [time].

    Raises [Invalid_argument] if [time] is before the session creation time. *)

val archive : t -> (t, Error.t) result
(** [archive t] is [t] marked archived.

    Archiving an archived session is idempotent. Returns {!Error.Active_turn} if
    [t] has an active turn. Returns {!Error.Deleted} if [t] is deleted. This
    does not change [updated_at]. *)

val restore : t -> (t, Error.t) result
(** [restore t] is [t] marked active.

    Restoring an active session is idempotent. Returns {!Error.Deleted} if [t]
    is deleted. This does not require the session to be idle and does not change
    [updated_at]. *)

val delete : t -> (t, Error.t) result
(** [delete t] is [t] marked deleted.

    Deleting a deleted session is idempotent. Returns {!Error.Active_turn} if
    [t] has an active turn. Archived sessions may be deleted. This does not
    change [updated_at]. *)

val fork :
  id:Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  t ->
  (t, Error.t) result
(** [fork ~id ?title ~cwd ~created_at t] is a new active session with [t]'s
    current semantic events and fork lineage pointing to [t].

    The parent may be active or archived, but must not have an unfinished turn.
    Returns {!Error.Active_turn} if [t] has an active turn. Returns
    {!Error.Deleted} if [t] is deleted. Raises [Invalid_argument] if [title] is
    empty. The child metadata [created_at] and [updated_at] are both set to
    [created_at]. *)

(** {1:rewind Rewind} *)

val resolve_anchor : Anchor.t -> t -> (int, Error.t) result
(** [resolve_anchor anchor t] is the copied-event prefix length [anchor] names
    in [t]: the number of leading events a child keeps.

    The cut is the exact event index of the named boundary. {!Anchor.Before}
    cuts at the [Turn_started] event index, so idle system, developer, and user
    messages appended after the previous turn finished are {e kept} in the
    prefix; {!Anchor.After} cuts just past the [Turn_finished] event index.
    Adjacent turns' [Before]/[After] edges therefore differ by any idle messages
    between them: [after_turn (n - 1)] resolves to a shorter prefix than
    [before_turn n] whenever such messages sit between turn [n - 1] and turn
    [n]. [before_turn] of the first turn keeps every idle event before that
    turn. It resolves to [0], producing a valid empty-log prefix equivalent to
    a fresh {!create}, only when that [Turn_started] is the first event.

    Returns {!Error.Unknown_turn} if the anchored turn is not in [t], and
    {!Error.Turn_not_finished} for an {!Anchor.After} anchor on a turn that has
    no terminal outcome. *)

val dropped_turns : Anchor.t -> t -> (Turn.Id.t list, Error.t) result
(** [dropped_turns anchor t] is the turns [anchor] drops, in start order: those
    whose [Turn_started] event index is at or after the resolved cut.

    This is one edge-uniform rule. For {!Anchor.Before} the cut is the turn's
    own [Turn_started] index, so the anchored turn and every later turn are
    dropped; for {!Anchor.After} the cut is just past the turn's [Turn_finished]
    index, so the anchored turn is kept and every later turn is dropped. Because
    {!State.turns} is in start order the result is always a suffix of it.

    Fails with the same errors as {!resolve_anchor}. The engine ledger revert
    and the TUI preview share this derivation rather than re-scanning. *)

val rewind :
  id:Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Time.t ->
  Anchor.t ->
  t ->
  (t, Error.t) result
(** [rewind ~id ?title ~cwd ~created_at anchor t] is a new active session whose
    events are [t]'s prefix up to [anchor] and whose {!Metadata.Forked_from}
    lineage points at [t] with [copied_events] set to the resolved prefix
    length.

    Like {!fork}, [t] must be not-deleted and have no active unfinished turn;
    the guard is on the {e parent} [t], so a [Before] anchor that would itself
    drop an active turn is still refused while [t] has one. Returns
    {!Error.Active_turn} or {!Error.Deleted} accordingly, and the anchor
    resolution errors of {!resolve_anchor}. The prefix always ends on a turn
    boundary, so replay validity holds by construction. When [anchor] names
    [t]'s last boundary this is exactly {!fork}. Raises [Invalid_argument] if
    [title] is empty. *)

val jsont : t Jsont.t
(** [jsont] maps sessions to JSON values. Decoding validates semantic event
    replay, validates metadata and nested event payloads, rejects unknown
    members, and rejects unsupported versions. *)

module Log : sig
  (** Low-level semantic log mutation.

      Ordinary host code should use the checked run planner. These functions are
      for import, migration, and replay tests that already own semantic event
      construction. *)

  val append : Event.t -> t -> (t, Error.t) result
  (** [append event t] is [t] with [event] appended.

      Returns {!Error.Archived} or {!Error.Deleted} if [t] is not active.
      Returns [Error (State e)] if applying [event] would violate semantic
      replay invariants. *)

  val append_all : Event.t list -> t -> (t, Error.t) result
  (** [append_all events t] appends [events] in list order.

      Returns the first error that would be returned by {!append}. On error no
      partial session is returned. *)
end
