(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable semantic session events.

    A session event is one durable semantic fact in a session log. Events
    reconstruct pure session state around a {!Spice_llm.Transcript.t}: accepted
    turns, appended model-visible messages, completed model responses,
    compactions, permission asks and replies, and terminal turn outcomes.

    Events are inert data. They do not contain session ids, document metadata,
    lifecycle status, log cursors, timestamps, callbacks, fibers, UI rows, live
    stream deltas, store records, or workspace evidence.

    Build events with the constructors below, then apply them with
    {!State.apply} or append them to a document with
    {!Spice_session.Log.append}. Event constructors check only local shape
    constraints; cross-event invariants such as active-turn ownership, pending
    tool calls, and terminal outcomes are checked during state replay. *)

(** The type for durable session events. *)
type t = private
  | Turn_started of Turn.t  (** An accepted turn started. *)
  | Message_appended of Spice_llm.Message.t
      (** A non-assistant model-visible message was appended. Assistant output
          produced by the model is recorded with {!Response_appended}. During
          replay, system, developer, and user messages require no active turn;
          tool results require an active turn and are checked by the transcript.
      *)
  | Response_appended of Spice_llm.Response.t
      (** A completed provider response was appended. Applying this event
          appends {!Spice_llm.Response.message} to the transcript. *)
  | Compaction_installed of Compaction.t
      (** Model replay history was replaced by a compacted transcript. *)
  | Permission_requested of Permission.Requested.t
      (** A protected operation is waiting for reviewer input. Applying this
          event requires no other unresolved durable waiting boundary. *)
  | Permission_resolved of Permission.Resolved.t
      (** A reviewer reply was applied to a pending permission request. A deny
          reply also carries the model-visible tool result that consumes the
          blocked tool call. *)
  | Tool_claim_started of Tool_claim.Started.t
      (** The host durably claimed an executable model tool call before running
          it. Applying this event requires no other unresolved durable waiting
          boundary. *)
  | Tool_claim_finished of Tool_claim.Finished.t
      (** A claimed executable tool call finished. Applying this event appends
          its model-visible tool result to the transcript. *)
  | Turn_finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
      (** An accepted turn reached a terminal outcome. Every outcome requires a
          ready transcript and no unresolved waiting. *)

val turn_started : Turn.t -> t
(** [turn_started turn] records accepted turn [turn]. *)

val message_appended : Spice_llm.Message.t -> t
(** [message_appended message] records a non-assistant model-visible message
    append.

    Raises [Invalid_argument] if [message] is an assistant message. Completed
    provider responses use {!response_appended} so response metadata is not
    lost. *)

val response_appended : Spice_llm.Response.t -> t
(** [response_appended response] records a completed provider response. *)

val compaction_installed : Compaction.t -> t
(** [compaction_installed compaction] records a model replay replacement. *)

val permission_requested : Permission.Requested.t -> t
(** [permission_requested request] records a pending permission request. *)

val permission_resolved : Permission.Resolved.t -> t
(** [permission_resolved reply] records a permission reply. *)

val tool_claim_started : Tool_claim.Started.t -> t
(** [tool_claim_started claim] records that [claim] was durably claimed before
    the host ran it. Replay requires no other unresolved durable permission or
    tool-claim boundary. *)

val tool_claim_finished : Tool_claim.Finished.t -> t
(** [tool_claim_finished claim] records a completed claim and its model-visible
    tool result. *)

val turn_finished : turn:Turn.Id.t -> Turn.Outcome.t -> t
(** [turn_finished ~turn outcome] records [turn]'s terminal outcome. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same event. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats an event for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps events to JSON values and rejects unknown event tags or unknown
    members. Decoding validates local event constructor constraints; replay
    validity is checked by {!State.of_events} and {!Spice_session.jsont}. *)
