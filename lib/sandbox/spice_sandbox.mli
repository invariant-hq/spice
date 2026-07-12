(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Command sandbox policies and platform lowering.

    This library defines what a spawned command may touch ({!Policy}), the
    enforcement evidence ({!Evidence}), backends that lower confined policies to
    platform enforcement ({!Backend}), and the sealed sandbox value tools
    consume.

    The usual flow is: the host resolves product configuration to a {!Policy.t},
    selects a backend, seals the sandbox with {!seal}, and hands the resulting
    {!type:t} to the shell tool. Status and explain commands render the same
    sandbox and backend facts instead of executing them.

    Sandboxing is not permission review. A sealed sandbox confines or refuses
    spawned commands; deciding whether Spice may attempt an operation at all
    belongs to [Spice_permission]. Process spawning itself stays in the tool
    layer. *)

module Error = Error
(** Structured sandbox errors. *)

module Policy = Policy
(** Pure command sandbox policies. *)

module Environment = Environment
(** Exact child environments owned by sandbox policies. *)

module Evidence = Evidence
(** Sandbox enforcement evidence. *)

module Argv = Argv
(** Non-empty process argv values accepted by {!spawn}.

    Use this module at the process boundary. It prevents the empty-argv case
    before a backend can wrap the command, while leaving permission-review
    command facts to [Spice_permission]. *)

module Backend = Backend
(** Confined-policy interpreters as values. *)

module Spawn = Run.Spawn
(** Prepared command spawn plans. *)

type t
(** A sealed command sandbox. This is what tools use to spawn. *)

type escalation = Run.escalation =
  | Available
  | Denied of Error.t
  | Ignored
      (** Per-command escalation stance.

          Escalation is a sandbox execution concept: it describes whether one
          command may run without the sealed confinement after separate
          permission review. *)

val spawn : t -> argv:Argv.t -> (Spawn.t, Error.t) result
(** [spawn t ~argv] is the complete spawn decision for one command.

    [Ok spawn] carries the argv to execute, the environment to pass to the
    process, and the evidence that the command result must report. Every route
    uses the exact environment carried by the sealed policy.

    [Error error] is a structured sandbox refusal. The command must not be
    spawned; callers that produce command output should report
    {!Evidence.refused}[ error]. *)

val spawn_escalated : t -> argv:Argv.t -> (Spawn.t, Error.t) result
(** [spawn_escalated t ~argv] prepares an approved escape from confined
    execution without escaping [t]'s exact child environment. *)

val escalation : t -> escalation
(** [escalation t] is the sealed escalation stance. *)

val evidence : t -> Evidence.t
(** [evidence t] is the sealed posture: the evidence every command from [t]
    reports, fixed at seal time before any command runs. Status, explain,
    run-start metadata, and the host require gate all read this. *)

val policy : t -> Policy.t
(** [policy t] is the exact policy sealed in [t]. *)

val seal : ?backend:Backend.t -> Policy.t -> t
(** [seal ?backend policy] seals [policy].

    [backend] defaults to a refusing backend, so the zero-configuration result
    is fail-closed for confined policies. Backend availability is evaluated
    here once, not per spawn. *)

module Seatbelt = Seatbelt
(** macOS Seatbelt lowering: pure profile generation plus the backend. *)

module Bubblewrap = Bubblewrap
(** Linux Bubblewrap backend identity and availability diagnostics. *)
