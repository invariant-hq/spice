(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Sandbox enforcement backends.

    A backend is a confined-policy interpreter as a value: an identity, an
    availability probe, and a preparation step that lowers one confined policy to an
    enforcement profile exactly once. Backends are consumed by hosts when
    sealing a sandbox; tools never see one.

    [available] and [prepare] may probe the host (platform, binaries);
    preparation generates the enforcement profile and its digest together, so
    the profile a command runs under and the hash the evidence reports cannot
    diverge, and per-spawn wrapping is a pure, infallible prefix application. *)

type t
(** The type for backends. *)

type prepared
(** A confined policy lowered by one backend: the enforcing argv prefix and the
    profile digest, generated together.

    Prepared values are intentionally opaque. Backend implementations create
    them with {!prepared}; callers can only wrap a command or inspect the
    digest. This keeps the command wrapper and the evidence hash coupled to the
    same generated profile. *)

val make :
  id:string ->
  available:(unit -> (unit, Error.t) result) ->
  prepare:(Policy.t -> (prepared, Error.t) result) ->
  unit ->
  t
(** [make ~id ~available ~prepare ()] is a backend.

    [prepare policy] generates the enforcement profile for [policy],
    or a structured error explaining why it cannot.

    Constructing a backend asserts enforcement authority: {!Spice_sandbox.seal}
    trusts a backend's self-reported [id] and [profile] to build
    {!Evidence.enforced}. Only host-selected backends should be constructed;
    tools never do.

    Raises [Invalid_argument] if [id] is empty. *)

val prepared :
  chdir:bool -> prefix:string list -> profile:Spice_digest.t -> prepared
(** [prepared ~chdir ~prefix ~profile] is a lowered confined policy. Wrapping a command
    yields [prefix] followed by the command's argv; because the command is a
    non-empty {!Argv.t}, the wrapped argv is always non-empty and the command's
    own tokens are preserved verbatim. [profile] is the digest of the generated
    enforcement profile. Backend implementations build this in their [prepare].
    When [chdir] is [true], wrapping inserts Bubblewrap's
    [--chdir CWD --] between the prefix and command.

    Raises [Invalid_argument] if [prefix] starts with an empty program name.

    A prefix cannot rewrite, reorder, or drop the command it wraps, only stand
    in front of it. This is misuse-resistance, not a security boundary: a prefix
    still names a trusted program that is expected to hand control to the
    command after applying the profile. *)

val none : reason:string -> t
(** [none ~reason] always refuses with [reason]: the fail-closed default and the
    unsupported-platform value.

    Raises [Invalid_argument] if [reason] is empty. *)

val id : t -> string
(** [id t] is the backend identity, for example ["macos-seatbelt"]. *)

val available : t -> (unit, Error.t) result
(** [available t] probes whether [t] can enforce policies on this host. *)

val prepare : t -> Policy.t -> (prepared, Error.t) result
(** [prepare t policy] lowers the confined [policy] with [t], generating the
    enforcement profile once. *)

val wrap : prepared -> cwd:Spice_path.Abs.t -> argv:Argv.t -> Argv.t
(** [wrap prepared ~cwd ~argv] is the enforcing argv around [argv]: the prepared
    prefix followed by [argv]'s tokens. Pure prefix application. *)

val profile : prepared -> Spice_digest.t
(** [profile prepared] is the digest of the prepared profile. *)
