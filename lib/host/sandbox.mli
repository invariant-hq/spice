(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host sandbox resolution.

    The adapter where sandbox mode, configuration, and platform backend
    selection meet. One {!resolve} produces the {!Effective.t} posture that
    feeds a run, the require {!gate}, and the status and explain commands, so
    they cannot disagree about what a command may touch.

    Two types carry the result, split by what they hold:

    - {!Effective.t} is authority. It holds the sealed {!Spice_sandbox.t} a tool
      spawns through, the host-resolved {!Spice_sandbox.Policy.t}, and the
      selected backend. Tools and the gate read it.
    - {!Status.t} is display. It is a detached record of posture facts with no
      sealed sandbox, safe to snapshot across a boundary — for example into TUI
      state — where holding a live {!Effective.t} would carry spawn authority it
      must not. Every product surface renders one {!Status.t}, so the surfaces
      speak one vocabulary.

    Mode precedence is CLI flag, then configured mode, then the built-in
    {!Mode.Workspace_write} default. Resolution never mutates anything. *)

(** {1:vocab Product vocabulary} *)

module Mode : sig
  (** Product sandbox modes selected by CLI and config. *)

  type t = Read_only | Workspace_write | Danger_full_access | External_sandbox

  val all : t list
  (** [all] are the modes in declaration order. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s CLI and config spelling, for example
      ["workspace-write"]. *)

  val of_string : string -> t option
  (** [of_string s] is the mode spelled [s], or [None] for an unknown spelling.
      Error wording belongs to the configuration boundary that parses user
      input, which builds it from {!all} and {!to_string}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same mode. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s spelling. *)
end

module Read : sig
  (** Filesystem read scope for confined commands. *)

  type t = Project | All

  val all : t list
  val to_string : t -> string
  val of_string : string -> t option
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

module Require : sig
  (** Product enforceability requirements. *)

  type t = Off | Enforced_or_external | Enforced

  val all : t list
  (** [all] are the requirements in declaration order. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s CLI and config spelling, for example
      ["enforced-or-external"]. *)

  val of_string : string -> t option
  (** [of_string s] is the requirement spelled [s], or [None] for an unknown
      spelling. Error wording belongs to the configuration boundary that parses
      user input, which builds it from {!all} and {!to_string}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same requirement. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s spelling. *)
end

module Network = Spice_sandbox.Policy.Network
(** Requested command network access. *)

type root_origin =
  | Project
  | Platform
  | Toolchain of string
  | Executable of string
  | Git_worktree
  | Scratch
  | User_configured
(** Why a physical root was admitted to a project-scoped policy. *)

val root_origin_to_string : root_origin -> string
(** [root_origin_to_string origin] is [origin]'s stable diagnostic spelling. *)

(** {1:gate Gate rejection} *)

module Gate_error : sig
  (** Reasons the require posture rejects a resolved sandbox. *)

  (** The type for gate rejection reasons. *)
  type t =
    | Backend_unavailable of { mode : Mode.t; reason : Spice_sandbox.Error.t }
        (** A confined [mode] was requested but its backend is unavailable, for
            [reason]. *)
    | External_not_enforced
        (** A declared external boundary does not satisfy a requirement of
            {!Require.Enforced}. *)

  val message : t -> string
  (** [message t] is a human-readable diagnostic with a recovery hint. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s {!message}. *)
end

module Resolve_error : sig
  (** Recoverable failures while constructing run-owned sandbox resources. *)

  type t =
    | Invalid_scratch_base of Spice_path.Error.t
    | Scratch_creation_failed of string
    | Invalid_environment of Spice_sandbox.Environment.Error.t
    | Invalid_root of {
        field : string;
        index : int option;
        spelling : string;
        reason : string;
      }
    | Broad_root of { field : string; path : Spice_path.Abs.t }
    | Redundant_readable_roots

  val message : t -> string
  val pp : Format.formatter -> t -> unit
end

(** {1:status Display posture} *)

module Status : sig
  (** Derived sandbox posture facts for product surfaces.

      A status value is the single vocabulary rendered by run-start summaries,
      [run.started] JSON, and [spice sandbox status]/[explain], and the detached
      snapshot carried into surfaces that must not hold a sealed sandbox. It is
      display data, not runtime authority; a run spawns through
      {!Effective.sandbox}. Its only producer is {!Effective.status}. *)

  type origin =
    | Flag
    | Config
    | Default  (** Where the effective mode came from. *)

  type network =
    | Restricted
    | Enabled
    | External
        (** Network posture. [External] means the declared boundary owns it. *)

  type t = {
    mode : Mode.t;
    read : Read.t;
    origin : origin;
    require : Require.t;
    enforcement : Spice_sandbox.Evidence.t;
    network : network;
    backend : string;
  }
  (** Derived posture facts. [read] is the confined filesystem read scope.
      [enforcement] is the sealed pre-spawn expectation:
      the {!Spice_sandbox.evidence} every command from the sealed sandbox
      reports. [backend] is the product display name: ["none"] for unconfined
      runs, ["external"] for declared boundaries, and the backend id for
      confined runs. [backend] is presentation data; use {!Effective.backend}
      when a backend value is needed. *)

  val available : t -> bool
  (** [available t] is [true] iff [t]'s [enforcement] is not
      {!Spice_sandbox.Evidence.Refused}: the platform can enforce the confined
      modes. It is the single availability predicate shared by
      [spice sandbox status]'s text and JSON renderers so they cannot disagree.
  *)

  val origin_string : origin -> string
  (** [origin_string origin] is ["flag"], ["config"], or ["default"]. *)

  val enforcement_string : Spice_sandbox.Evidence.t -> string
  (** [enforcement_string enforcement] is ["enforceable"], ["refused"],
      ["not_requested"], or ["declared"]. *)

  val network_string : network -> string
  (** [network_string network] is ["restricted"], ["enabled"], or ["external"].
  *)
end

(** {1:effective Resolved posture} *)

module Effective : sig
  (** The resolved sandbox posture handed to a run and to status surfaces.

      An effective value is authority: it retains the host-resolved
      {!Spice_sandbox.Policy.t}, the selected backend, and the sealed
      {!Spice_sandbox.t}. Status surfaces project {!status}; tools receive only
      {!sandbox}. *)

  type t
  (** The type for a resolved sandbox posture for one run or one status query.
  *)

  val policy : t -> Spice_sandbox.Policy.t
  (** [policy t] is the mode lowered to a sandbox policy with canonicalized
      writable and protected paths. This is status metadata, not spawn
      authority. *)

  val read : t -> Read.t
  (** [read t] is the selected confined read scope. *)

  val roots : t -> (root_origin * Spice_path.Abs.t) list
  (** [roots t] are project-scoped physical roots paired with their admission
      reason. Scratch is present for every route. *)

  val readable_roots : t -> Spice_path.Abs.t list
  (** [readable_roots t] is the resolved root allowlist for project-scoped
      reads, including runtime and toolchain roots. It is [[]] for all-host,
      direct, and external routes. *)

  val backend : t -> Spice_sandbox.Backend.t
  (** [backend t] is the selected host backend. This is the platform candidate:
      its id names what the platform could enforce, independent of whether [t]'s
      mode requests confinement. See {!Status.backend} for the mode-dependent
      display name. *)

  val writable_roots : t -> Spice_path.Abs.t list
  (** [writable_roots t] are the effective confined writable roots. *)

  val protected_paths : t -> Spice_path.Abs.t list
  (** [protected_paths t] are concrete write-protected paths. *)

  val environment_names : t -> string list
  (** [environment_names t] are the exact child binding names. *)

  val sandbox : t -> Spice_sandbox.t
  (** [sandbox t] is {!policy} sealed against {!backend}: the value the shell tool
      spawns through. *)

  val status : t -> Status.t
  (** [status t] is the derived {!Status.t} for product output and detached
      snapshots. It is recomputed from {!policy}, {!sandbox}, and {!backend}; it
      does not grant authority to spawn. *)
end

(** {1:resolution Resolution and gating} *)

val resolve :
  sw:Eio.Switch.t ->
  ?flag:Mode.t ->
  ?config_mode:Mode.t ->
  ?require:Require.t ->
  ?protect:Spice_path.Abs.t list ->
  ?read:Read.t ->
  ?readable_roots:string list ->
  ?writable_roots:string list ->
  ?network:Network.t ->
  ?workspace_trusted:bool ->
  stdenv:Eio_unix.Stdenv.base ->
  env:(string -> string option) ->
  project_root:Spice_path.Abs.t ->
  workspace:Spice_workspace.t ->
  unit ->
  (Effective.t, Resolve_error.t) result
(** [resolve ~sw ~stdenv ~env ~project_root ~workspace ()] resolves the
    effective posture.

    [flag] is the per-run CLI override and wins over [config_mode], which wins
    over the built-in default {!Mode.Workspace_write}. [require] defaults to
    {!Require.Enforced}. [protect] are additional protected absolute paths
    (Spice's own store paths); it defaults to none.

    Resolution creates a mode-[0700] scratch directory owned by [sw]. Every
    child route receives it as [HOME], [TMPDIR], [TMP], and [TEMP], and confined
    backends make only that private temporary directory writable. Workspace
    roots remain writable in workspace-write mode. [stdenv] supplies the
    process and clock capabilities for a bounded platform availability probe.
    [workspace_trusted] defaults to [false]. When [true], existing canonical
    project-local [_opam/bin] directories lead the exact child [PATH];
    restricted workspaces never contribute executable roots.
    [env] supplies [$TMPDIR] and the private deterministic host test seam:
    [_SPICE_TEST_SANDBOX_UNAVAILABLE=1] forces the refusing backend, while
    [_SPICE_TEST_BUBBLEWRAP_PROBE] substitutes only the availability probe
    executable. Neither seam changes a production enforcement prefix.

    [read] defaults to {!Read.All}. Under a confined {!Read.Project} mode,
    [project_root], workspace roots, [readable_roots], executable search roots,
    and non-system, non-broad installation prefixes containing [bin]/[sbin].
    Conventional system prefixes contribute only existing [etc], [lib],
    [libexec], and [share] siblings. OCaml toolchain roots and the platform
    runtime profile complete the read allowlist.
    [project_root] identifies the enclosing project for reads, linked Git
    metadata, and trusted local executables; only workspace roots become
    automatically writable.
    User roots must exist, resolve physically, and may not name filesystem root,
    the account home, or an ancestor of the account home. Direct and external
    modes do not resolve or validate confined read roots and preserve the
    inherited executable search path.

    [writable_roots] are configured extra writable directories for
    workspace-write. They obey the same spelling and validation rules as
    [readable_roots]. Both lists accept absolute or [~]-prefixed spellings and
    default to none.

    [network] is the requested outbound-network capability for the confined
    modes; it defaults to {!Network.Restricted}.

    Resolution does not gate: a resolved posture may still be rejected by
    {!gate}. *)

val gate : Effective.t -> (unit, Gate_error.t) result
(** [gate effective] applies the require posture. It is pure and must run before
    any credential loading or session mutation, so an unenforceable run fails
    closed before it can touch credentials or persist state.

    A confined request whose backend is unavailable fails under
    {!Require.Enforced} and {!Require.Enforced_or_external}. A declared external
    boundary fails only under {!Require.Enforced}. Unconfined requests and
    {!Require.Off} always pass. Passing the gate with {!Require.Off} does not
    run refused confined commands unconfined: each shell command is still
    refused by the sealed sandbox if no backend can enforce it. *)

val mutating_tools : Effective.t -> bool
(** [mutating_tools effective] is [false] iff the effective mode is
    {!Mode.Read_only}: a read-only run's catalog must not contain built-in
    mutating tools, so the run cannot mutate the workspace through them either.
    Pass it to the catalog builder's [mutating] parameter. *)
