(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure reconstructed session state.

    A state value is the semantic projection of durable {!Event.t} values. It
    reconstructs accepted turns, terminal outcomes, a checked model-visible
    {!Spice_llm.Transcript.t}, latest provider replay data, pending permission
    prompts, installed compactions, derived waiting, and runtime permission
    grants reconstructed from stored permission replies.

    State is inert data. It does not contain session ids, document metadata,
    lifecycle status, log cursors, timestamps, stores, model clients, executable
    tools, fibers, callbacks, UI rows, live stream deltas, workspace evidence,
    or product projections.

    State values are normally obtained from {!of_events} or
    {!Spice_session.state}. Use {!apply} to validate one proposed semantic event
    against an existing projection and use the typed errors below for recovery
    or diagnostics. *)

(** {1:errors Errors} *)

module Error : sig
  (** State reconstruction errors. *)

  module Turn : sig
    (** Turn state errors. *)

    type t =
      | Active of Turn.Id.t
          (** An event requiring no active turn was applied while this turn was
              active. *)
      | No_active
          (** An event requiring an active turn was applied while no turn was
              active. *)
      | Duplicate of Turn.Id.t  (** A turn start reused an existing turn id. *)
      | Unknown of Turn.Id.t
          (** An event referenced a turn that has not started. *)
      | Finished of Turn.Id.t
          (** An event referenced a turn that already reached a terminal
              outcome. *)
      | Response_model_mismatch of {
          turn : Turn.Id.t;
          expected : Spice_llm.Model.t;
          actual : Spice_llm.Model.t;
        }
          (** A completed response was recorded with a requested model different
              from the active turn's model. *)
      | Unresolved_waiting of Turn.Id.t
          (** A clean terminal outcome was applied while the turn still had
              unresolved waiting boundaries. *)
  end

  module Permission : sig
    (** Permission prompt state errors. *)

    type t =
      | Duplicate of Permission.Id.t
          (** A permission request reused an existing permission request id. *)
      | Unknown of Permission.Id.t
          (** A permission reply referenced an unknown permission request. *)
      | Not_pending of Permission.Id.t
          (** A permission reply referenced a request that is no longer pending.
          *)
      | Tool_call_not_pending of {
          permission : Permission.Id.t;
          call_id : string;
        }
          (** A permission request referenced a tool call that is not currently
              pending in the transcript. *)
      | Result_mismatch of {
          permission : Permission.Id.t;
          expected_call_id : string;
          expected_name : string;
          actual_call_id : string;
          actual_name : string;
        }
          (** A denied permission produced a result for a different tool call
              than the one it blocked. *)
  end

  module Tool_claim : sig
    (** Tool claim state errors. *)

    type t =
      | Duplicate of Tool_claim.Id.t
          (** A started tool claim reused an existing tool claim id. *)
      | Unknown of Tool_claim.Id.t
          (** A finished tool claim referenced an unknown tool claim id. *)
      | Not_pending of Tool_claim.Id.t
          (** A finished tool claim referenced a claim that is no longer
              pending. *)
      | Result_bypasses_claim of {
          execution : Tool_claim.Id.t;
          call_id : string;
        }
          (** A raw tool-result event attempted to answer a call owned by a
              pending durable claim. *)
      | Tool_call_not_pending of {
          execution : Tool_claim.Id.t;
          call_id : string;
        }
          (** A started tool claim referenced a tool call that is not currently
              pending in the transcript. *)
      | Result_mismatch of {
          execution : Tool_claim.Id.t;
          expected_call_id : string;
          expected_name : string;
          actual_call_id : string;
          actual_name : string;
        }
          (** A finished tool claim produced a result for a different tool call
              than the one it started. *)
  end

  type t =
    | Turn of Turn.t  (** The event violates turn state. *)
    | Permission of Permission.t
        (** The event violates permission prompt state. *)
    | Tool_claim of Tool_claim.t  (** The event violates tool claim state. *)
    | Transcript of Spice_llm.Transcript.Error.t
        (** Applying the event would violate transcript grammar. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The returned string is suitable for display and logs, but is not stable
      machine-readable syntax. Callers and tests that need stable behavior
      should inspect [e] directly. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. The output is not stable storage
      syntax. *)
end

(** {1:states States} *)

type t
(** The type for pure reconstructed session state.

    Invariant:

    - turn ids are unique;
    - at most one turn is active;
    - turn starts append their user input to the transcript;
    - completed responses append their assistant message to the transcript;
    - active-turn tool results are checked by {!Spice_llm.Transcript};
    - compactions require a request-ready current transcript and a request-ready
      replacement transcript, and leave any active turn active;
    - permission request ids are unique;
    - permission requests reference the active unfinished turn and a pending
      model tool call;
    - permission answers reference pending requests and update grants through
      {!Spice_permission.Policy.Review.answer}; denied permission answers answer
      the exact blocked model tool call;
    - tool claim ids are unique;
    - tool claims reference the active unfinished turn and a pending model tool
      call;
    - tool claim results reference pending claims and answer the exact started
      model tool call;
    - every terminal turn outcome requires no unresolved waiting boundaries and
      a request-ready transcript;
    - transcript updates preserve {!Spice_llm.Transcript} invariants. *)

val empty : t
(** [empty] is the state before any session event has been applied. *)

val apply : Event.t -> t -> (t, Error.t) result
(** [apply event t] is [t] after applying [event].

    Returns [Error e] if [event] would violate a state invariant. The input
    state is immutable and can be reused after an error. *)

val apply_all : Event.t list -> t -> (t, Error.t) result
(** [apply_all events t] applies [events] to [t] in list order.

    Returns the first error encountered. *)

val of_events : Event.t list -> (t, Error.t) result
(** [of_events events] reconstructs state from [events] in list order.

    [of_events events] is [apply_all events empty]. *)

(** {1:transcript Transcript} *)

val transcript : t -> Spice_llm.Transcript.t
(** [transcript t] is [t]'s checked model-visible transcript. *)

val final_text : t -> string option
(** [final_text t] is the text of the most recent assistant message in [t]'s
    transcript that carries text, or [None] when no assistant message carries
    any. Multiple text blocks are joined with a newline and the result is
    trimmed; an assistant message whose text is empty or all-whitespace is
    skipped, so the result is the last model-authored prose. *)

(** {1:replay_usage Replay Usage} *)

val replay_usage : t -> (Spice_llm.Usage.t * Spice_llm.Message.t list) option
(** [replay_usage t] is the provider-reported usage baseline of the current
    model-visible replay, if any: the most recent response usage together with
    the transcript suffix appended after that response — the messages whose cost
    the usage does not yet cover.

    The baseline is cleared when a compaction replaces the replay: usage
    measured against the pre-compaction replay does not describe the
    replacement. Responses without usage leave the previous baseline standing.
    Without a baseline, project from {!transcript} directly. *)

(** {1:compactions Compactions} *)

val compactions : t -> Compaction.t list
(** [compactions t] is [t]'s installed compactions in event application order.
*)

val latest_compaction : t -> Compaction.t option
(** [latest_compaction t] is the most recently installed compaction, if any. *)

(** {1:turns Turns} *)

val turns : t -> Turn.t list
(** [turns t] is [t]'s accepted turns in start order. *)

val turn : Turn.Id.t -> t -> Turn.t option
(** [turn id t] is the turn identified by [id], if any. *)

val active_turn : t -> Turn.Id.t option
(** [active_turn t] is the active unfinished turn, if any. *)

val turn_outcome : Turn.Id.t -> t -> Turn.Outcome.t option
(** [turn_outcome id t] is the terminal outcome of turn [id], if [id] has
    finished. *)

val turn_response_count : Turn.Id.t -> t -> int option
(** [turn_response_count id t] is the number of model responses appended for
    turn [id], if [id] is known. The active turn's count increases on
    {!Event.Response_appended} only. *)

val turn_final_text : Turn.Id.t -> t -> string option
(** [turn_final_text id t] is the latest non-empty assistant text appended
    during turn [id], if [id] is known and has produced model-authored prose.
    Multiple text blocks are joined with a newline and trimmed. Tool-only and
    whitespace-only responses do not replace an earlier text for the same turn.
*)

val latest_model : t -> Spice_llm.Model.t option
(** [latest_model t] is the active turn's model, or the most recently started
    turn's model when no turn is active. This is the model the session would
    continue with absent an explicit override. *)

(** {1:permissions Permissions} *)

val pending_permissions : t -> Permission.Requested.t list
(** [pending_permissions t] is the unresolved permission requests that currently
    block the active turn, in request order. *)

val pending_permission : Permission.Id.t -> t -> Permission.Requested.t option
(** [pending_permission id t] is pending permission request [id], if it is still
    blocking the active turn. *)

val permissions :
  t -> (Permission.Requested.t * Permission.Resolved.t option) list
(** [permissions t] is every permission request and its optional reply, in
    request order. *)

(** {1:tool_claims Tool claims} *)

val pending_tool_claims : t -> Tool_claim.Started.t list
(** [pending_tool_claims t] is the started executable tool calls with no
    recorded result that currently block the active turn, in start order. *)

val pending_tool_claim : Tool_claim.Id.t -> t -> Tool_claim.Started.t option
(** [pending_tool_claim id t] is pending tool claim [id], if it is still
    blocking the active turn. *)

val tool_claims :
  t -> (Tool_claim.Started.t * Tool_claim.Finished.t option) list
(** [tool_claims t] is every tool claim and its optional result, in start order.
    A valid terminal turn has no unfinished claim. *)

val waiting : t -> Waiting.t list
(** [waiting t] is the current active turn's durable waiting boundaries, with
    pending permissions first in request order followed by pending tool claims
    in start order. *)

val grants : t -> Spice_permission.Policy.Grants.t
(** [grants t] is the runtime permission grants reconstructed from durable
    permission replies. Only allow-session replies add grants; allow-once
    permits the already-blocked operation and denial adds no grant. *)
