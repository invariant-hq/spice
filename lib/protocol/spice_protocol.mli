(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure language a spice session speaks.

    [spice_protocol] has three public seams:

    - execution requests and results: {!Command}, {!Event}, {!Outcome},
      {!Pending}, and {!Error};
    - host-workflow vocabulary with independent artifact lifecycles:
      {!Question}, {!Plan}, {!Todo}, {!Goal}, {!Subagent}, {!Subagent_run},
      {!Call}, {!Mode}, and {!Contract};
    - presentation and replay projections: {!Session_summary},
      {!Subagent_progress}, and {!Event.of_session}.

    These seams compose, but workflow artifacts are not merely command/event
    payloads: hosts persist and transition them through their own boundaries.

    The library is pure: it links no transport, no store, and no effectful
    engine. It carries no wire codecs — there is no transport yet to validate
    them — but every payload admitted into {!Command.t} or {!Event.t} is either
    already persisted by the session store (hence codec-able) or carries an
    obvious wire projection. Two payloads keep in-process-only richness that a
    wire projection drops to serializable output plus {!Spice_mutation} facts:
    an {!Event.t}'s tool results retain typed {!Spice_tool.Output.t} evidence,
    and {!Command.Finish_tool} carries the same result shape. *)

module Contract = Contract
(** The read-only vocabulary shared by modes and roles. *)

module Question = Question
(** The user-question host tool. *)

module Plan = Plan
(** Plan artifacts and the plan-approval boundary. *)

module Todo = Todo
(** Session-local todos. *)

module Goal = Goal
(** Session goal artifacts and the goal continuation boundary. *)

module Subagent = Subagent
(** Subagent contracts and spawn requests. *)

module Subagent_progress = Subagent_progress
(** Live, identity-tagged subagent child progress events. *)

module Subagent_run = Subagent_run
(** Subagent run records. *)

module Call = Call
(** Host-tool call classification and the host-tool kind enumeration. *)

module Mode = Mode
(** Primary turn modes. *)

module Notice = Notice
(** Ephemeral host notices for model-request injection. *)

module Model_artifact = Model_artifact
(** Local model artifact facts. *)

module Command = Command
(** The session execution ingress. *)

module Outcome = Outcome
(** Where an execution step settled. *)

module Pending = Pending
(** The typed pending-boundary projection a decision dialog renders. *)

module Error = Error
(** The session execution error taxonomy. *)

module Event = Event
(** The session egress language. *)

module Session_summary = Session_summary
(** Typed projection for listing saved sessions. *)
