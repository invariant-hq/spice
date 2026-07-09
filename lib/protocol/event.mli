(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** One renderable fact about a session, live or replayed.

    An event is the session's egress language: {!Command.t} in, {!t} out. It is
    the single event surface, replacing the hand-written interpreters that each
    consumer used to derive tool lifecycle, host-call classification, and final
    assistant text.

    Events split into two kinds:

    - {b durable} events mirror saved session facts. They are emitted during a
      live run only after their underlying session events are saved, and the
      same values are produced by {!of_session} from a saved document. The two
      agree up to {!Host_call} folding: a live run emits {!Host_call} twice per
      answered call (pending then resolved), while {!of_session} emits the
      resolved one only, so the durable subsequence of the live stream equals
      {!of_session} after replacing each pending {!Host_call} with its
      same-call-id resolved emission. See the cardinality note on {!of_session}.
    - {b live-only} events are progress deltas — model streaming, tool updates,
      workspace and compaction progress, notice injection — that a saved
      document cannot reconstruct. {!of_session} never produces them.

    {!is_durable} decides the split for a given event, so consumers do not
    re-derive it from documentation. *)

(** {1:progress Compaction progress} *)

(** The type for what grounded a compaction projection. *)
type basis =
  | Usage  (** Grounded in provider-reported replay usage. *)
  | Estimate  (** Derived from the approximate token estimator. *)

(** The type for a live-only compaction progress delta.

    A pressure or overflow attempt emits {!Started}, then {!Summarizing} and
    zero or more {!Retrying}, and terminates in either a durable
    {!type:t}[.Compaction] (installed) or a live-only {!Skipped} or {!Failed}.
    It carries no installed compaction — that fact is durable. *)
type compaction_progress =
  | Started of {
      reason : Spice_session.Compaction.Reason.t;
      projected_input : int;  (** The projection the trigger decided with. *)
      basis : basis;  (** What grounded [projected_input]. *)
      auto_limit : int option;
          (** The policy limit the trigger compared against, when any. *)
    }  (** A compaction attempt started, before its summary request is built. *)
  | Summarizing of Spice_llm.Request.t
      (** A summary model request is about to be sent. *)
  | Retrying of { dropped_messages : int }
      (** Summary generation hit context overflow and will retry with fewer
          historical messages. *)
  | Skipped of { reason : Spice_session.Compaction.Reason.t; message : string }
      (** The attempt found nothing to summarize and installed nothing. *)
  | Failed of { reason : Spice_session.Compaction.Reason.t; message : string }
      (** The attempt failed before installing a durable compaction. *)

(** {1:events Events} *)

(** The type for a session event. *)
type t =
  (* Durable — also produced by {!of_session}. *)
  | Turn_started of Spice_session.Turn.t  (** A turn began. *)
  | Assistant of Spice_llm.Response.t
      (** The model produced an assistant response. *)
  | Tool_started of Spice_session.Tool_claim.Started.t
      (** An executable tool claim was saved and is about to run. The started
          claim carries the model call and the claim id, so no separate
          [call_id -> name] correlation table is needed. *)
  | Tool_finished of {
      claim : Spice_session.Tool_claim.Started.t;
      result : Spice_tool.Output.t Spice_tool.Result.t;
    }
      (** An executable tool returned a terminal result for [claim]. [result]
          carries the erased output, including retained typed evidence. *)
  | Host_call of {
      call : Spice_llm.Tool.Call.t;
      kind : Call.t option;
          (** The classified host call ({!Call.classify} [call]). [None] means
              the call was recorded as host-handled by its turn — its name is in
              {!Spice_session.Turn.host_tools} — but is not a tool the current
              vocabulary classifies, e.g. a turn saved by an older or newer tool
              set. Renderers fall back to a generic host-call row. *)
      result : Spice_llm.Tool.Result.t option;
          (** [None] while the call is pending; [Some _] once answered. See the
              cardinality note below. *)
    }
      (** A host-handled tool call, correlated with its eventual answer. This
          one fact replaces both consumers' "a host tool was called" plus "it
          was answered" string-matching. *)
  | Permission_requested of Spice_session.Permission.Requested.t
      (** A permission review is pending. *)
  | Permission_resolved of Spice_session.Permission.Resolved.t
      (** A permission review was resolved. *)
  | Compaction of Spice_session.Compaction.t
      (** A durable compaction was installed. *)
  | Turn_finished of {
      turn : Spice_session.Turn.Id.t;
      outcome : Spice_session.Turn.Outcome.t;
      final_text : string option;
          (** The finished turn's last non-empty assistant text, computed once
              during projection; no transcript back-walking in consumers. *)
    }  (** A turn reached a terminal outcome. *)
  (* Live-only — never produced by {!of_session}. *)
  | Assistant_delta of { text : string }
      (** A fragment of the current model step's visible assistant text, in
          stream order. Emitted zero or more times during a model step, strictly
          before the durable {!Assistant} of that same step. The durable
          {!Assistant} is authoritative: a frontend that ignores deltas renders
          exactly what it does today, and a frontend that accumulates them
          discards its buffer when the durable event lands, so settled text
          equals streamed text. *)
  | Reasoning_delta of { text : string }
      (** A fragment of the current model step's reasoning summary, in stream
          order, before the step's durable {!Assistant}. Same authority rule as
          {!Assistant_delta}: the durable {!Assistant}'s
          {!Spice_llm.Response.reasoning_summary} is authoritative, and an
          accumulating frontend discards its buffer when it lands. *)
  | Usage_updated of Spice_llm.Usage.t
      (** The provider's usage snapshot for the current model step's response.
          Its counts are cumulative within that one response — the tokens the
          provider attributes to producing this step — not a delta since the
          last snapshot and not a running total across the turn; a frontend that
          wants turn spend sums the per-step snapshots itself.

          Emitted in stream order before the step's durable {!Assistant}, at
          most once per model step and only when the provider reports usage
          (providers report it on their terminal stream event, so it lands at
          the step's end). It is a live progress signal only: the durable
          per-response usage is carried by that step's {!Assistant} response and
          the turn total by {!Turn_finished}, so {!of_session} never produces
          this event and a frontend that ignores it loses no durable fact. *)
  | Model_started of Spice_llm.Request.t
      (** An ordinary model request is about to be sent. *)
  | Model_artifact of Model_artifact.progress
      (** A provider-owned local artifact is being prepared before a request. *)
  | Tool_updated of {
      claim : Spice_session.Tool_claim.Started.t;
      update : Spice_tool.Update.t;
    }
      (** An executable tool emitted a progress update. Carries the claim, not a
          bare call id. *)
  | Workspace_changed of {
      claim : Spice_session.Tool_claim.Started.t;
      checkpoint : Spice_mutation.Checkpoint.t option;
      changes : Spice_mutation.Change.t list;
      total : Spice_mutation.Change.totals;
    }
      (** Workspace mutation evidence was recorded for [claim]. [checkpoint] is
          the run checkpoint captured before the first mutation when present,
          [changes] are this claim's rows, and [total] is run-cumulative. *)
  | Workspace_degraded of { message : string }
      (** Workspace mutation evidence was lost or incomplete; the tool result
          itself is unaffected. *)
  | Compaction_progress of compaction_progress
      (** A compaction delta; see {!type:compaction_progress}. *)
  | Notices_injected of Notice.t list
      (** Pending host notices were drained into the next model-request prelude.
      *)

val is_durable : t -> bool
(** [is_durable event] is [true] iff [event] is a durable event — one that
    {!of_session} can produce from a saved document. It is [false] for every
    live-only progress delta. *)

val of_session : Spice_session.t -> t list
(** [of_session session] is the durable projection of [session]: the durable
    events above, in transcript order, with host calls classified and final turn
    text computed. Host-call recognition uses the catalog recorded on each
    call's own turn; a tool offered by an earlier turn does not carry into a
    later turn. Live-only events are never produced.

    {b Host_call cardinality.} An event stream cannot mutate a past fact, so a
    live run emits {!Host_call} twice for one call: once with [result = None]
    when the call is first seen (pending), and once with [result = Some _] when
    it is answered, both carrying the same {!Spice_llm.Tool.Call.t} identity. A
    consumer correlates the pair by call id and replaces the pending row. By
    contrast {!of_session} emits exactly one {!Host_call} per call: with
    [result = Some _] when the transcript records the answer, or [result = None]
    for a call that is still the session's current unanswered host-tool
    boundary. *)
