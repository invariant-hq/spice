(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Sandbox enforcement evidence.

    Evidence states what actually guarded a spawned command. It is owned by the
    sandbox library — not by any tool — because tool output, JSONL events, and
    status rendering all speak it.

    [Not_requested] means the host chose unconfined execution, including a
    user-approved per-command escalation. [Enforced] records the backend and the
    digest of the generated enforcement profile. [Refused] means a restricted
    sandbox was requested but could not be enforced, so the command was not
    spawned. [Declared_external] reports the user's declared external boundary;
    it is never upgraded to enforced. *)

type t = private
  | Not_requested
  | Enforced of { backend : string; profile : Spice_digest.t }
  | Refused of Error.t
  | Declared_external
      (** The type for sandbox enforcement evidence.

          Values are private so callers may inspect evidence but must use the
          constructors below to preserve enforced-evidence invariants. *)

val not_requested : t
(** [not_requested] reports that no command confinement was requested. *)

val declared_external : t
(** [declared_external] reports a user-declared external boundary. *)

val enforced : backend:string -> profile:Spice_digest.t -> t
(** [enforced ~backend ~profile] reports backend enforcement with the generated
    profile digest.

    Raises [Invalid_argument] if [backend] is empty. *)

val refused : Error.t -> t
(** [refused error] reports that a requested restricted sandbox refused to
    spawn.

    Use this evidence when {!Spice_sandbox.spawn} returns [Error error] or when
    an enforcing wrapper could not be started. The error remains structured;
    human-readable messages are diagnostics, not matching keys. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same evidence. *)

val to_json : t -> Jsont.json
(** [to_json t] is the canonical JSON projection: an object whose ["kind"]
    member discriminates the variant, with ["backend"] and ["profile_hash"] for
    [Enforced] and ["reason"] for [Refused]. [profile_hash] is lowercase
    hexadecimal.

    Every product JSON surface (model-visible tool output, JSONL events) uses
    this one spelling so evidence cannot drift between contracts. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats evidence for diagnostics. The output is not stable storage
    syntax. *)
