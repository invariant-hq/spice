(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The session execution error taxonomy.

    This is the error a client sees when a {!Command.t} cannot be carried out:
    execution failures plus the persistence failures that occur while a workflow
    saves documents. Constructors are grouped by caller recovery path, not by
    source library. *)

(** The type for a session execution error. *)
type t =
  | Conflict of {
      id : Spice_session.Id.t;
      expected : Spice_session.Revision.t;
      actual : Spice_session.Revision.t;
    }
      (** The document changed after [expected] was observed. [expected] and
          [actual] are the store revision tokens observed and currently
          persisted; a client cannot mint or resubmit them, only reload.
          Recovery: reload and retry. *)
  | Not_found of Spice_session.Id.t
      (** A document needed by the workflow no longer exists. *)
  | Storage of { path : string; message : string }
      (** Persisted data at [path] is corrupt or a filesystem operation failed,
          including a host-tool handler's sidecar write. Recovery: inspect the
          store below [path]. *)
  | Provider of Spice_llm.Error.t
      (** A model client call failed; branch on {!Spice_llm.Error.kind}. *)
  | Invalid_answer of string
      (** A host-handled tool answer was invalid (e.g. empty). *)
  | Archived of Spice_session.Id.t
      (** The operation requires a non-archived session. *)
  | Deleted of Spice_session.Id.t
      (** The operation requires a non-deleted session. *)
  | Active_turn_exists of Spice_session.Turn.Id.t
      (** An idle-session operation ran while this turn was active. *)
  | No_active_turn  (** The operation requires an active turn. *)
  | Permission_not_pending of Spice_session.Permission.Id.t
      (** A permission reply referenced no pending request. *)
  | Permission_rule_save_failed of {
      path : string;
      message : string;
      hints : string list;
    }
      (** User-scoped permission rules could not be saved. The permission
          remains pending and the blocked operation did not start. *)
  | Permission_rule_saved of { path : string; resolution_error : t }
      (** User-scoped permission rules were saved at [path], but the session
          resolution was not appended by this command and the blocked operation
          did not start. Retrying the reply is safe. *)
  | Tool_claim_not_pending of Spice_session.Tool_claim.Id.t
      (** A tool-claim recovery referenced no pending unfinished claim. *)
  | Tool_call_not_pending of { call_id : string; name : string }
      (** A {!Command.Answer} referenced no pending matching host-tool call: the
          session's current boundary is not that host-tool call (it may be
          waiting on a permission, a different call, or nothing). *)
  | Transcript_not_ready of Spice_llm.Transcript.Error.t
      (** Compaction requires a request-ready transcript. *)
  | Nothing_to_summarize
      (** No transcript prefix was eligible for compaction. *)
  | No_compaction_model
      (** No policy model and no prior turn model were available. *)
  | Empty_compaction_summary  (** The summary model returned only empty text. *)
  | Internal of string
      (** A lower-layer invariant was violated. Recovery: report a bug. *)

val message : t -> string
(** [message e] is a human-readable diagnostic. *)

val diagnostic : t -> Spice_diagnostic.t
(** [diagnostic e] renders [e] as a diagnostic, with actionable hints on
    recovery-bearing constructors. A {!Permission_rule_saved} diagnostic
    offers both an idempotent retry and explicit removal of the saved rule. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf e] formats [e] for diagnostics. *)
