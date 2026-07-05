(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure command-sandbox modelling and platform lowering.

    This library defines what a spawned command may touch ({!Confinement}), the
    enforcement evidence ({!Evidence}), backends that lower confinement to
    platform enforcement ({!Backend}), and the sealed sandbox value tools
    consume.

    The usual flow is: the host resolves product configuration to a {!Spec.t},
    selects a backend, seals the sandbox with {!seal}, and hands the resulting
    {!type:t} to the shell tool. Status and explain commands render the same
    sandbox and backend facts instead of executing them.

    Sandboxing is not permission review. A sealed sandbox confines or refuses
    spawned commands; deciding whether Spice may attempt an operation at all
    belongs to [Spice_permission]. Process spawning itself stays in the tool
    layer. *)

module Error = Error
(** Structured sandbox errors. *)

module Confinement = Confinement
(** Pure confinement descriptions. *)

module Env = Env
(** Diagnostic environment filtering policy.

    This module is for sandbox status and explain surfaces that need to describe
    the filtering policy without spawning. Common spawn callers should use
    {!spawn}; the resulting {!Spawn.t} reports the filtered environment and
    stripped names for the actual command. *)

module Evidence = Evidence
(** Sandbox enforcement evidence. *)

module Argv = Argv
(** Non-empty process argv values accepted by {!spawn}.

    Use this module at the process boundary. It prevents the empty-argv case
    before a backend can wrap the command, while leaving permission-review
    command facts to [Spice_permission]. *)

module Backend = Backend
(** Confinement interpreters as values. *)

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

val spawn :
  t -> argv:Argv.t -> env:(string * string) list -> (Spawn.t, Error.t) result
(** [spawn t ~argv ~env] is the complete spawn decision for one command.

    [Ok spawn] carries the argv to execute, the environment to pass to the
    process, the stripped environment names, and the evidence that the command
    result must report. For confined sandboxes the argv may be wrapped by the
    prepared backend and [env] is filtered with {!Env.partition}; for unconfined
    and declared-external sandboxes both pass through unchanged.

    [Error error] is a structured sandbox refusal. The command must not be
    spawned; callers that produce command output should report
    {!Evidence.refused}[ error]. *)

val escalation : t -> escalation
(** [escalation t] is the sealed escalation stance. *)

val evidence : t -> Evidence.t
(** [evidence t] is the sealed posture: the evidence every command from [t]
    reports, fixed at seal time before any command runs. Status, explain,
    run-start metadata, and the host require gate all read this. *)

module Spec : sig
  type t =
    | Unconfined
    | Declared_external
    | Confined of Confinement.t
        (** Host-resolved command sandbox posture before backend sealing. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same sandbox posture. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a sandbox posture for diagnostics. *)
end

val seal : ?backend:Backend.t -> Spec.t -> t
(** [seal ?backend spec] seals [spec].

    [backend] defaults to a refusing backend, so the zero-configuration result
    is fail-closed for confined requests. Backend availability is evaluated
    here, once, not per spawn. *)

module Seatbelt = Seatbelt
(** macOS Seatbelt lowering: pure profile generation plus the backend. *)

module Bubblewrap = Bubblewrap
(** Linux Bubblewrap backend identity and availability diagnostics. *)
