(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A configured coding run.

    A {!t} is the product's definition of a runnable coding turn, assembled once
    and host-side: the workspace, the gated sandbox and permission posture, the
    model and client, the workspace context and skills, the tool catalog, the
    run configuration, the compaction policy, the live notice machinery, and the
    interpreter itself. It is what the CLI and TUI previously built by hand as
    ~100 lines of copied assembly and a duplicated child-run orchestration.

    A run is transparent, not an engine: {!runner} is the assembled interpreter,
    but every other part is a value a deviating consumer can read and recombine
    ({!context}, {!skills}, {!tools}, {!Toolset.make}). The whole waist is
    {!plan} then {!start} then driving {!runner} — or {!Live} — with
    {!Spice_protocol.Command.t} and rendering {!Spice_protocol.Event.t}.

    {2:fail_closed The two-stage fail-closed contract}

    Resolution splits into two stages so the fail-closed ordering is a fact of
    the types, not a doc-comment protocol:

    - {!plan} is pure. It {e gates} the sandbox — the require posture that must
      hold before any credential loads or state persists — and bundles the
      readable posture (sandbox and permission). It fails closed on an
      unenforceable sandbox, before {!start} can touch credentials.
    - {!start} is effectful. It takes a {!Plan.t} — which only {!plan} produces,
      so no run starts on an ungated sandbox — plus the credentialed client, and
      assembles the interpreter.

    The stages are separate because the ordering is user-observable: a caller
    prints the run-start posture summary from a {!Plan.t} {e between} {!plan}
    and {!start}, then resolves the model and builds the client (both of which
    may fail {e after} the summary), then calls {!start}. *)

(** {1:plan Planning} *)

module Plan : sig
  (** A gated, readable run posture.

      A plan is the product of a successful sandbox gate. It carries the posture
      a run-start summary renders — the effective sandbox and the permission
      table — and is the token {!start} requires, so the type guarantees a run's
      sandbox was gated before it started. *)

  type t
  (** The type for a gated run posture. *)

  val workspace : t -> Spice_workspace.t
  (** [workspace t] is the run's workspace. *)

  val sandbox : t -> Sandbox.Effective.t
  (** [sandbox t] is the gated effective sandbox. Project
      {!Sandbox.Effective.status} for the run-start summary. *)

  val permission : t -> Config.Source.t Permission.Run.t
  (** [permission t] is the run's permission table. Read
      {!Permission.Run.preset} for the run-start summary. *)
end

val plan :
  workspace:Spice_workspace.t ->
  sandbox:Sandbox.Effective.t ->
  permission:Config.Source.t Permission.Run.t ->
  unit ->
  (Plan.t, Sandbox.Gate_error.t) result
(** [plan ~workspace ~sandbox ~permission ()] gates [sandbox] and bundles the
    run posture.

    [sandbox] and [permission] are resolved by the caller — their resolution
    (protected paths, preset overrides) is frontend-specific — and passed in as
    the fail-closed gated values. [plan] applies {!Sandbox.gate}: an
    unenforceable confined run fails here with a {!Sandbox.Gate_error.t},
    {e before} any credential is loaded. On success the returned {!Plan.t} is
    the token {!start} requires and the posture the caller's summary renders. *)

(** {1:run The run} *)

type t
(** The type for an assembled coding run. Its notice producers must be released
    with {!stop} when the run ends. *)

val start :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  Host.t ->
  Plan.t ->
  mode:Spice_protocol.Mode.t ->
  model:Spice_provider.Model.t ->
  client:Spice_llm.Client.t ->
  store:Spice_session_store.t ->
  session:Spice_session.Id.t ->
  http:Cohttp_eio.Client.t ->
  fetch_https:Spice_tools.Web_fetch.https ->
  ?max_steps:int ->
  ?skills:Skills.t ->
  ?cwd_override:Spice_path.Abs.t ->
  unit ->
  (t, Host.Error.t) result
(** [start ~sw ~stdenv host plan ~mode ~model ~client ~store ~session ~http
     ~fetch_https ()] assembles the run over [plan]'s gated posture.

    It loads the workspace {!Context}, loads {!Skills} (unless [skills] reuses a
    preloaded snapshot), extends the context prelude with [mode]'s messages,
    builds the {!Toolset} catalog filtered by [mode]'s
    {!Spice_protocol.Contract}, assembles the {!Spice_session.Run.Config},
    derives the compaction policy, starts the notice producers, creates the
    mutation recorder, and constructs the {!runner}: an interpreter over [store]
    and [client] whose host-tool dispatch is {!Handler.defaults} — with subagent
    spawning owned here — and whose hooks are the shared notice-injection and
    mutation-evidence recording. A consumer adds its own observer, terminal, or
    after-save hooks with {!Runner.with_hooks}, or hands {!runner} to
    {!Live.attach}.

    [client] is the credentialed client the caller built from [plan] and [model]
    after printing the run-start summary; the credential ordering stays with the
    caller. [http] and [fetch_https] are the HTTPS transport the host does not
    own. [max_steps] is the effective per-run step limit; [session] seeds the
    anchored-edit resolver and roots the mutation store and workflow artifacts;
    [cwd_override] is the run-directory fallback for {!Context.eio_cwd}.

    Subagent children run through the assembled {!jobs} registry; a surface
    that renders child progress live subscribes with {!Jobs.subscribe}. The
    headless path simply does not subscribe and runs children silently.

    Errors are {!Host.Error.t}: {!Host.Error.Instructions} from prelude
    construction, {!Host.Error.Workspace} from context loading, and skill-load
    failures. *)

val jobs : t -> Jobs.t
(** [jobs t] is the subagent run registry the assembled handler spawns
    through. Surfaces subscribe to it for identity-tagged child progress and
    settlement events; its children run on [start]'s [sw]. *)

val stop : t -> unit
(** [stop t] stops [t]'s notice producers and the Dune RPC instance they own.
    Idempotent for the run switch's lifetime; call it once the run ends. *)

(** {1:parts Assembled parts}

    The parts of the assembled run a consumer reads: attach extra hooks onto
    the {!runner}, report from the {!context}, and drain the {!notices}. *)

val runner : t -> Runner.t
(** [runner t] is the assembled interpreter: [store], [client], run config,
    {!Handler.defaults} host-tool dispatch, compaction policy, and the shared
    notice and mutation hooks. Compose extra {!Session} hooks onto it with
    {!Runner.with_hooks}, or attach it with {!Live.attach}. *)

val workspace : t -> Spice_workspace.t
(** [workspace t] is the run's workspace. *)

val cwd : t -> Spice_path.Abs.t
(** [cwd t] is the resolved run directory (see {!Context.cwd}). *)

val context : t -> Context.t
(** [context t] is the loaded workspace context. Read {!Context.rendered_digest}
    and {!Context.warnings} for run-start reporting. *)

val notices : t -> Notice_queue.t
(** [notices t] is the run's notice queue, drained into request preludes by the
    runner's notice hook. *)
