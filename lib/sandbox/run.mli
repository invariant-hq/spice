(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Internal sealed sandbox implementation.

    This module backs {!type:Spice_sandbox.t}, the host-sealed answer to "what
    does this sandbox do to a spawned command": how argv is wrapped, which exact
    environment is used, what evidence is reported, and whether per-command
    escalation is available. It composes a sandbox posture with a {!Backend.t}
    once, at resolve time -- the same moment the host's require gate runs.

    Backend availability is evaluated at sealing, not per spawn: a confined
    sandbox sealed against an unavailable backend refuses every command with the
    backend's reason. *)

type t
(** The type for sealed command sandboxes. *)

type escalation =
  | Available
  | Denied of Error.t
  | Ignored
      (** Per-command escalation stance.

          [Available] under confinement with writable roots (workspace-write
          shaped). [Denied reason] under confinement without writable roots: a
          read-only run's no-mutation promise admits no approval-shaped
          exception. [Ignored] for unconfined and declared-external requests,
          where escalation asks for what is already true. *)

module Spawn : sig
  type t
  (** A spawn plan. The command has not been started. *)

  val cwd : t -> Spice_path.Abs.t
  (** [cwd t] is the canonical working directory the process must use. *)

  val argv : t -> Argv.t
  (** [argv t] is the argv the host should spawn. *)

  val env : t -> (string * string) list
  (** [env t] is the environment the host should pass to the process. *)

  val evidence : t -> Evidence.t
  (** [evidence t] is the sandbox evidence the host should report for the
      command result. *)
end

val seal : ?backend:Backend.t -> Policy.t -> t
(** [seal ?backend policy] seals [policy].

    Direct and external policies need no backend. Confined policies are lowered
    once by [backend]. [backend] defaults to a refusing backend, so a confined
    zero-configuration result is fail-closed. *)

val policy : t -> Policy.t
(** [policy t] is the exact policy sealed in [t]. *)

val spawn :
  t -> cwd:Spice_path.Abs.t -> argv:Argv.t -> (Spawn.t, Error.t) result
(** [spawn t ~cwd ~argv] is the complete spawn decision for one command.

    [Ok spawn] carries the argv to spawn, the policy's exact environment, and the
    evidence the result must report. [Error refusal] is a structured refusal
    error: the command must not be spawned, and the result reports
    {!Evidence.refused}[ refusal].

    The returned [Spawn.t] is a plan only; this module never starts a process.
*)

val spawn_escalated :
  t -> cwd:Spice_path.Abs.t -> argv:Argv.t -> (Spawn.t, Error.t) result
(** [spawn_escalated t ~cwd ~argv] drops filesystem and network confinement only
    when {!escalation}[ t] is {!Available}. The returned spawn still uses the
    policy's exact environment. Denied and nonsensical escalation requests are
    structured errors and start no process. *)

val escalation : t -> escalation
(** [escalation t] is the sealed escalation stance. *)

val evidence : t -> Evidence.t
(** [evidence t] is the sealed posture: the evidence every command from [t]
    reports, fixed at seal time before any command runs. Status, explain,
    run-start metadata, and the host require gate all read this. *)
