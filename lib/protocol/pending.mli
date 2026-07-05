(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The typed pending-boundary projection a decision dialog renders.

    A blocked step settles {!Outcome.Waiting} carrying the product-agnostic
    {!Spice_session.Waiting.t} and, for a host-tool boundary, the pre-applied
    {!Call.t} classification. This module folds those two fields into one sum
    naming exactly the decision the user must make, so a frontend picks a dialog
    and renders it without re-decoding the call or re-matching the waiting.

    It is the single host-call classification path a frontend consumes:
    {!of_outcome} is defined {e over} {!Outcome}'s own [call] field, never
    re-classifying the raw call, so this projection and {!Outcome} cannot drift.
    A new dialog-worthy host tool is a new arm here — a compile error at every
    match, which is the intent. *)

type t =
  | Permission of Spice_session.Permission.Requested.t
      (** A tool needs a permission the policy will not grant on its own. *)
  | Plan of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      proposal : Plan.Proposal.t;
    }  (** A well-formed [propose_plan] parked the turn on the plan boundary. *)
  | Question of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      question : Question.Request.t;
    }  (** A well-formed [ask_user] parked the turn on the question boundary. *)
  | Host_tool of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      call : Call.t;
    }
      (** A classified host call that is neither a plan nor a question — a todo,
          goal, or subagent call, or an {!Call.Invalid} payload the user must
          unblock with a correction ({!Call.answerable_question}). *)

val of_outcome : Outcome.t -> t option
(** [of_outcome o] is the typed boundary [o] blocked on, or [None] when [o] is
    {!Outcome.Finished}, a tool-claim wait, an executable-tool wait, or a
    host-tool wait whose call the current tool vocabulary cannot classify (a
    replay-only edge — a live run shares the vocabulary, so its host-tool waits
    always classify). It reads {!Outcome}'s pre-applied [call] field rather than
    re-running {!Call.classify}, so the projection agrees with [o] by
    construction: a {!Call.Plan} becomes {!Plan}, a {!Call.Question} becomes
    {!Question}, and every other classified call — including {!Call.Invalid} —
    becomes {!Host_tool}. *)

val turn : t -> Spice_session.Turn.Id.t
(** [turn t] is the turn [t] blocks. For a {!Permission} it is the turn the
    durable request records. *)

val call_id : t -> string option
(** [call_id t] is the model tool-call id [t] answers, or [None] for a
    {!Permission} (whose boundary is named by its prompt id, not a call id). *)
