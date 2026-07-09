(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A configured session interpreter.

    A runner is the pure planner's effectful interpreter, reified as a value. It
    holds its injected parts — store, client, run config, host-tool handler,
    compaction policy, hooks — and no session state: every {!execute} takes and
    returns documents explicitly. Construction is pure; effects happen per call.

    The interpreter's testability seam is a scripted {!Spice_llm.Client}, not an
    assembled effects record; {!make} is the sole public constructor.

    Save-before-effect ordering, at-most-once tool claims, compaction guards,
    and notice commit/rollback are the interpreter's contract: planned events
    are saved before every model request and before every executable tool claim,
    and an executable tool runs at most once per saved claim. *)

type t
(** The type for a configured interpreter. *)

val make :
  store:Spice_session_store.t ->
  client:Spice_llm.Client.t ->
  model:Spice_llm.Model.t ->
  mode:Spice_protocol.Mode.t option ->
  run:Spice_session.Run.Config.t ->
  ?host_tool:Handler.t ->
  ?resolve_plan:Session_loop.plan_resolver ->
  ?compaction:Compactor.Policy.t ->
  ?hooks:Session.hooks ->
  unit ->
  t
(** [make ~store ~client ~model ~mode ~run ?host_tool ?resolve_plan ?compaction
    ?hooks ()] is an interpreter over [store] and [client] with effective turn
    [model], optional root [mode], and run configuration [run]. These bound
    values, plus [run]'s host-tool catalog, are the only source of persisted
    turn contract facts; {!Spice_protocol.Command.Start} supplies request data
    only.

    [host_tool] answers caller-owned host-tool calls; calls it does not answer
    remain blocked for the caller to resolve. [resolve_plan] applies a
    {!Spice_protocol.Command.Resolve_plan} decision host-side (the durable plan
    transition and the answer wording); it defaults to a resolver that reports
    {!Spice_protocol.Error.Internal}, so a runner that never hosts plan-mode
    turns need not supply one. [compaction], when present, enables pressure
    compaction before large ordinary requests and one overflow-recovery
    compaction after a context overflow. [hooks] defaults to
    {!Session.no_hooks}. *)

val with_hooks : (Session.hooks -> Session.hooks) -> t -> t
(** [with_hooks f t] is [t] with its hooks replaced by [f]'s result, composing
    additional {!Session} hook combinators onto the existing ones. [t] is
    unchanged; a new interpreter is returned.

    This is the seam an attachment uses to tap the interpreter without
    rebuilding it: {!Live} derives its drained runner with
    [with_hooks (fun h -> h |> Session.with_observe tap |>
     Session.with_cancelled flag)] so it can observe the event stream and own
    cancellation over a runner the consumer already configured. The combinators'
    own composition rules apply — {!Session.with_observe} and
    {!Session.with_cancelled} replace the prior callback, so a caller wanting to
    keep an existing observer chains it explicitly through {!Session.observe}.
*)

val execute :
  t ->
  Spice_session_store.Document.t ->
  Spice_protocol.Command.t ->
  ( Spice_session_store.Document.t * Spice_protocol.Outcome.t,
    Spice_protocol.Error.t )
  result
(** [execute t document command] interprets [command] against [document] until
    the session blocks or finishes, returning the latest saved document beside
    its {!Spice_protocol.Outcome.t}. The document travels here because the
    protocol outcome carries the boundary only.

    Every {!Spice_protocol.Command.t} is handled here — there are no verb
    wrappers. Preconditions (idle vs active session, present pending permission
    or host-tool call) are checked per command and reported through
    {!Spice_protocol.Error.t}: e.g. a {!Spice_protocol.Command.Start} on a
    session with an active turn is {!Spice_protocol.Error.Active_turn_exists}, a
    {!Spice_protocol.Command.Resume} with no active turn is
    {!Spice_protocol.Error.No_active_turn}. On a host-tool block the returned
    {!Spice_protocol.Outcome.Waiting} carries the classified [call]. *)
