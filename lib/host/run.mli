(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A configured coding run.

    A {!t} is the assembled workspace posture of a coding session, built once
    and host-side: the workspace, the gated sandbox and permission posture, the
    workspace context and skills, the live notice machinery, and the subagent
    job registry. It holds no mode, no model, and no credential — those are
    facts of a turn's contract, not of the workspace — so assembly never fails
    on provider state, and its cost (context load, producers, watches) is paid
    once per session rather than per turn.

    A run is transparent, not an engine: {!runner} derives the interpreter for
    one turn contract, and every other part is a value a deviating consumer can
    read and recombine ({!context}, {!Toolset.make}). The whole waist is
    {!plan}, then {!start}, then {!runner} per turn contract, then driving the
    interpreter — or {!Live} — with {!Spice_protocol.Command.t} and rendering
    {!Spice_protocol.Event.t}.

    {2:fail_closed The fail-closed contract}

    Resolution splits into three steps so the fail-closed ordering is a fact of
    the types, not a doc-comment protocol:

    - {!plan} is pure. It {e gates} the sandbox — the require posture that must
      hold before any credential loads or state persists — and bundles the
      readable posture (sandbox and permission). It fails closed on an
      unenforceable sandbox, before any credential is touched.
    - {!start} is effectful but credential-free. It takes a {!Plan.t} — which
      only {!plan} produces, so no run assembles on an ungated sandbox — and
      loads the workspace: context, skills, producers, jobs.
    - {!runner} is the per-turn derivation. It takes the turn's contract — the
      mode, the model, and the credentialed client the caller resolved for it —
      and derives the interpreter over the assembled workspace.

    The steps are separate because the ordering is user-observable — a caller
    prints the run-start posture summary from a {!Plan.t} between {!plan} and
    the first credential load — and because the turn contract is a per-turn
    fact: a frontend re-resolves the model and rebuilds the client from the
    current credential store at every turn, so a login or a model switch takes
    effect on the next turn without reassembling the workspace. *)

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
  (** [permission t] is the run's permission table, including the rules a
      confining sandbox credits into the posture (see
      {!Permission.Run.with_sandbox_backing}). Display surfaces read this table
      — not the pre-plan posture — so denial provenance explains the decision
      the run actually made. Read {!Permission.Run.preset} for the run-start
      summary. *)
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
(** The type for an assembled coding run. Close it with {!close} when the run
    ends. *)

val start :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  Host.t ->
  Plan.t ->
  store:Spice_session_store.t ->
  session:Spice_session.Id.t ->
  http:Cohttp_eio.Client.t ->
  fetch_https:Spice_tools.Web_fetch.https ->
  ?max_steps:int ->
  ?skills:Skills.t ->
  ?cwd_override:Spice_path.Abs.t ->
  unit ->
  (t, Host.Error.t) result
(** [start ~sw ~stdenv host plan ~store ~session ~http ~fetch_https ()]
    assembles the workspace run over [plan]'s gated posture.

    It loads the workspace {!Context}, loads {!Skills} (unless [skills] reuses a
    preloaded snapshot), starts the notice producers, creates the {!jobs}
    registry and the mutation recorder, and wires the shared notice-injection
    and mutation-evidence hooks. It touches no credential and resolves no model:
    the turn contract binds later, in {!runner}.

    [http] and [fetch_https] are the HTTPS transport the host does not own.
    [max_steps] is the effective per-run step limit; [session] seeds the
    anchored-edit resolver and roots the mutation store and workflow artifacts;
    [cwd_override] is the run-directory fallback for {!Context.eio_cwd}.

    Subagent children run through the assembled {!jobs} registry; a surface that
    renders child progress live subscribes with {!Jobs.subscribe}. The headless
    path simply does not subscribe and runs children silently.

    Errors are {!Host.Error.t}: {!Host.Error.Workspace} from context loading,
    and skill-load failures. *)

val jobs : t -> Jobs.t
(** [jobs t] is the subagent run registry the assembled handler spawns through.
    Surfaces subscribe to it for identity-tagged child progress and settlement
    events; its children run on [start]'s [sw]. *)

val close : t -> (unit, Jobs.Close_error.t) result
(** [close t] closes the child registry and then stops every notice producer
    and Dune RPC instance created by {!start}. It returns only after child
    attachments can no longer emit or mutate state. Producer teardown still
    runs when a child ledger transition fails. Closing is idempotent. *)

(** {1:parts The interpreter and assembled parts}

    The interpreter derives per turn contract; every other part is a value a
    consumer reads: report from the {!context}, drain the {!notices}. *)

val runner :
  t ->
  mode:Spice_protocol.Mode.t ->
  model:Spice_provider.Model.t ->
  client:Spice_llm.Client.t ->
  (Runner.t, Host.Error.t) result
(** [runner t ~mode ~model ~client] derives the interpreter for one turn
    contract over the assembled workspace.

    It extends the context prelude with [mode]'s messages, builds the {!Toolset}
    catalog for [model] filtered by [mode]'s {!Spice_protocol.Contract},
    assembles the {!Spice_session_run.Config}, derives the compaction policy
    from [model], and constructs the interpreter over the run's store and
    [client] whose host-tool dispatch is {!Handler.defaults} — with subagent
    spawning owned here, children bound to this contract's [client] — and whose
    hooks are the assembled notice-injection and mutation-evidence recording.
    Compose extra {!Session} hooks onto the result with {!Runner.with_hooks}, or
    hand it to {!Live.attach} / {!Live.set_runner}.

    [client] is the credentialed client the caller resolved for [model] from the
    current credential store; re-deriving at each turn is how a login or a model
    switch takes effect mid-session. The derivation is cheap — pure assembly
    over the loaded workspace — and starts no producer. The interpreter binds
    [mode], [model], and its effective tool catalogs; a submitted
    {!Spice_protocol.Command.Start} cannot override those persisted facts.

    Errors are {!Host.Error.t}: {!Host.Error.Instructions} from prelude
    construction. *)

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
