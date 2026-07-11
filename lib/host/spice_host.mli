(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host runtime workflow facade.

    Hosts combine effective configuration with deterministic static provider
    declarations, then interpret those values for application and CLI tasks
    without redefining provider or model identities.

    This module is the public facade for the [spice_host] library. It re-exports
    the host modules and groups the assembly glue that binds them — loading a
    host, building a credentialed client, and the model-artifact workflows —
    over the protocol vocabulary in {!Spice_protocol}.

    The main journey is {!Run}: {!Run.plan} resolves the fail-closed posture,
    {!Run.start} assembles the interpreter, and a consumer drives {!Runner} or
    {!Live} with {!Spice_protocol.Command.t} and renders
    {!Spice_protocol.Event.t}. *)

(** {1:setup Setup} *)

module Env = Env
(** Process environment snapshots shared by host services. *)

module Config = Config
(** Host configuration. *)

module User_dirs = User_dirs
(** User config, durable-data, and machine-state directory resolution. *)

module Workspace_state = Workspace_state
(** Global checkpoint and review state keyed by canonical workspace root. *)

module Trust = Trust
(** Persistent consent for ambient project customization. *)

module Host = Host
(** Loaded host values: the error taxonomy, the provider adapter and registry,
    and host loading. *)

module Account = Account
(** Passive host account workflows, credential-source interpretation, and
    provider client construction. *)

module Models = Models
(** Deterministic host model selection: explained role resolution, user-input
    resolution, and run gates. *)

module Reason = Reason
(** Explanations for host decisions. *)

(** {1:posture Run posture} *)

module Permission = Permission
(** Product permission posture: presets, unattended reply policy, rule identity,
    and the provenance-carrying rule table. *)

module Sandbox = Sandbox
(** Host sandbox resolution: effective posture, require gate, and display
    status. *)

module Turn_options = Turn_options
(** Model-conditioned request options for one turn; the single seam both
    frontends assemble turn options through. *)

(** {1:context Workspace context} *)

module Context = Context
(** Request-scoped workspace context: instruction discovery facts and the
    model-visible projection. *)

module Skills = Skills
(** Request-scoped skill snapshot: every candidate skill across every root, the
    shadow/disable/invalid reasons, and the budgeted catalog the model sees. *)

(** {1:sessions Sessions} *)

module Notice_queue = Notice_queue
(** The capacity-bounded, fiber-safe queue of pending host notices injected
    before ordinary model requests. *)

module Compactor = Compactor
(** Session transcript compaction policy and context-pressure facts. *)

module Mutations = Mutations
(** Durable workspace mutation evidence: the content-addressed blob store, the
    per-session JSONL ledger, and the checkpoint backend record. Facts and pure
    combinators live in {!Spice_mutation}. *)

module Artifacts = Artifacts
(** Sidecar-backed persistence of the protocol workflow artifacts: plans, todos,
    and subagent runs, plus the plan-approval boundary. *)

module Handler = Handler
(** Host-tool dispatch as a composable value over {!Spice_protocol.Call.t}: todo
    writes, plan proposals, goal reports, subagent spawns, and questions. *)

module Goal_run = Goal_run
(** Goal lifecycle verbs, per-turn accounting, context injection, and the
    continuation decision both drivers consult. *)

module Session = Session
(** The effectful session boundary: store resolution, hooks, session birth,
    listing, compaction, and title workflows. *)

module Runner = Runner
(** The configured session interpreter as a value: {!Runner.make} injects the
    store, client, run config, handler, and hooks; {!Runner.execute} advances a
    document under a {!Spice_protocol.Command.t}. *)

module Live = Live
(** The stateful attachment to one session: a single-drain command loop over
    {!Runner.execute} owning the current document, cancellation, and event
    fan-out. The headless CLI drives {!Runner.execute} directly; the interactive
    surface attaches one per session. *)

(** {1:run The run waist} *)

module Toolset = Toolset
(** The standard coding-session tool catalog: builtins, web, and skills,
    sandbox-filtered and anchor-aware. Public because [spice debug tools] builds
    it standalone. *)

module Jobs = Jobs
(** The subagent run registry: mints child sessions, records the run ledger,
    runs each child as its own {!Live} attachment, and fans identity-tagged
    progress and settlement events out to subscribers. *)

module Run = Run
(** The run waist: {!Run.plan} resolves the fail-closed posture, {!Run.start}
    assembles workspace, context, skills, tools, notice producers, mutations,
    handler and interpreter, and {!Run.close} tears the whole owned run down. *)

(** {1:assembly Assembly glue} *)

val bootstrap :
  stdenv:Eio_unix.Stdenv.base ->
  registry:Host.Provider_registry.t ->
  ?cwd:string ->
  ?overrides:Config.Patch.t list ->
  unit ->
  (Host.t, Host.Error.t) result
(** [bootstrap ~stdenv ~registry ()] loads a host.

    It snapshots the process environment, loads the effective {!Config} for
    [cwd] (default the current directory) under [overrides], and loads the
    {!Host} for [registry]. Config failures are {!Host.Error.Config}, so startup
    is one {!Host.Error.t} sequence. *)

val client :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  ?observe_model_artifact:(Spice_protocol.Model_artifact.progress -> unit) ->
  ?name:Spice_account.Credential.Name.t ->
  ?process:Spice_account.Credential.t list ->
  Host.t ->
  Spice_provider.Model.t ->
  (Spice_llm.Client.t, Host.Error.t) result
(** [client ~sw ~stdenv host model] is a provider client for [model]'s provider.

    It loads credential sources for [host], resolves the provider credential,
    reads the provider base URL override, finds the provider's adapter, and
    builds the client. [name] selects the stored credential name and defaults to
    {!Spice_account.Credential.Name.default}; [process] overrides process
    credentials as in {!Account.load}.

    No cached validity is consulted: the first provider request is the
    validation. Stored OAuth credentials near expiry are refreshed before the
    client is built — a permanent refresh rejection fails with
    {!Host.Error.Blocked_credential} — and clients for refreshable OAuth routes
    retry one request once after a provider [Auth] failure when a forced refresh
    produced a replacement credential. A permanent forced-refresh rejection or
    replacement-client build failure supersedes the provider's stale auth error
    and is returned from the stream with its host diagnostic and repair hint.

    If the adapter exposes a model-artifact preparation capability, the returned
    client prepares [model] before the first stream and reports progress through
    [observe_model_artifact] when supplied. Preparation failures are returned as
    provider-boundary {!Spice_llm.Error.t} values from the stream call. Shared
    callers prepare once: concurrent first streams wait for the same preparation
    boundary, and a failed preparation leaves a later stream free to retry.

    All failure modes are {!Host.Error.t}: {!Host.Error.Unknown_provider},
    {!Host.Error.Credentials}, {!Host.Error.Blocked_credential},
    {!Host.Error.No_adapter}, and adapter build errors such as
    {!Host.Error.Missing_credential} — the adapter, not a host gate, decides
    whether a missing credential is an error, so an optional-auth provider
    builds a bare client — {!Host.Error.Unsupported_credential}, or
    {!Host.Error.Client}.

    {b Warning.} The returned client holds credential material and borrows [sw]
    and [stdenv] for transport. *)

val model_artifact_status :
  Host.t ->
  Spice_provider.Model.t ->
  Spice_protocol.Model_artifact.status option
(** [model_artifact_status host model] is the host-owned local artifact status
    for [model], when the provider adapter exposes one. *)

val download_model_artifact :
  Host.t ->
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  ?observe:(Spice_protocol.Model_artifact.progress -> unit) ->
  force:bool ->
  Spice_provider.Model.t ->
  Spice_protocol.Model_artifact.download_outcome option
(** [download_model_artifact host ~sw ~stdenv ~force model] fetches and installs
    [model]'s local artifact through its provider adapter.

    It is [None] when [model]'s provider registers no model-artifact capability,
    which is every hosted provider. Otherwise it is [Some outcome]: the adapter
    resolves the artifact status and, if the artifact is missing, downloads and
    verifies it, reporting progress through [observe]. [force] overrides a
    provider guard such as a memory-budget refusal. *)

val workspace : Host.t -> (Spice_workspace.t, Host.Error.t) result
(** [workspace host] is the single-root workspace at [host]'s configured working
    directory. *)

val default_ignore : Spice_path.Rel.t -> bool
(** [default_ignore path] is [true] when any workspace-relative path component
    is [".git"], ["_build"], ["_opam"], or [".spice"]. It is the
    filesystem-watch ignore predicate the run's producers use, exposed for
    surfaces that walk the workspace themselves. *)
