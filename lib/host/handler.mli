(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host-tool dispatch as a value.

    A handler tries to answer a model-visible tool call whose execution the host
    owns — a todo write, a plan proposal, a goal report, a subagent spawn —
    rather than the executable tool runner. It is the shape the interpreter
    injects as its host-tool seam: the loop offers each pending host-tool call
    to the handler, continues the turn on [Some result], and parks the turn on
    [None].

    {!defaults} is the whole host-tool dispatch as one value. It classifies a
    call once with {!Spice_protocol.Call.classify} and matches the resulting
    sum, rather than switching on tool names and re-decoding per tool. {!first}
    and {!for_tool} compose a custom handler ahead of the defaults. *)

type t =
  cancelled:(unit -> bool) ->
  Spice_session_store.Document.t ->
  Spice_llm.Tool.Call.t ->
  (Spice_llm.Tool.Result.t option, Spice_protocol.Error.t) result
(** The type for a host-tool handler.

    [Ok None] leaves the call for another handler or parks the turn on it;
    [Ok (Some result)] is the model-visible answer that continues the turn.
    Handler failures are execution failures: a storage failure surfaces as
    {!Spice_protocol.Error.Storage}, while an undecodable payload is a
    model-visible error {!Spice_llm.Tool.Result.t}, not a caller error — the
    model can then correct its call.

    [cancelled] is the turn's interrupt signal, the same flag the loop samples
    between steps. Most handlers answer promptly and never read it; a handler
    that blocks — [wait_subagents] — must sample it so an interrupt reaches a
    parked drain instead of waiting out the block. *)

(** {1:combinators Combinators} *)

val first : t list -> t
(** [first handlers] tries each handler in order and returns the first
    [Ok (Some _)]. Dispatch order is explicit data, not a hand-written
    fall-through. A handler error short-circuits. *)

val for_tool : string -> t -> t
(** [for_tool name handler] runs [handler] only for calls whose tool name is
    [name], and is [Ok None] for every other call. It gates a custom handler on
    a single tool. *)

val subagent :
  mode:Spice_protocol.Mode.t ->
  spawn:
    (Spice_protocol.Subagent.Spawn.t ->
    parent:Spice_session_store.Document.t ->
    (string, string) result) ->
  wait:
    (cancelled:(unit -> bool) ->
    Spice_protocol.Subagent.Wait.Request.t ->
    (string, string) result) ->
  cancel:(Spice_protocol.Subagent.Cancel.Request.t -> (string, string) result) ->
  message:(Spice_protocol.Subagent.Message.Request.t -> (string, string) result) ->
  t
(** [subagent ~mode ~spawn ~wait ~cancel ~message] is the host-tool dispatch
    for subagent runners. It gives a child the same bounded collaboration
    operations as its parent: spawn (with [mode]'s role gate), wait, cancel, and
    message. A valid [message_parent] returns [Ok None], parking the turn on the
    waiting boundary the run registry reads as an ask.

    Root workflow tools remain unavailable: questions, plans, todos, and goals
    answer with a model-visible error, so a child cannot mutate or park on the
    root session's workflow state. Calls that are not host tools are [Ok None].
    Undecodable offered collaboration calls answer with their decode error. *)

(** {1:defaults Default dispatch} *)

val defaults :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  now:(unit -> Spice_session.Time.t) ->
  mode:Spice_protocol.Mode.t ->
  spawn:
    (Spice_protocol.Subagent.Spawn.t ->
    parent:Spice_session_store.Document.t ->
    (string, string) result) ->
  wait:
    (cancelled:(unit -> bool) ->
    Spice_protocol.Subagent.Wait.Request.t ->
    (string, string) result) ->
  cancel:(Spice_protocol.Subagent.Cancel.Request.t -> (string, string) result) ->
  message:(Spice_protocol.Subagent.Message.Request.t -> (string, string) result) ->
  t
(** [defaults ~fs ~root ~now ~mode ~spawn ~wait ~cancel ~message] is the
    built-in host-tool dispatch. It classifies each call once and answers by
    kind:

    - {b Todo.} A valid [todo_write] replaces the session's stored list below
      [root] and answers with a confirmation.
    - {b Plan.} A valid [propose_plan] saves the proposal as
      {!Spice_protocol.Plan.Status.Proposed} and returns [Ok None]: the turn
      parks exactly like a question, and the interpreter reports the block with
      the classified plan. When a proposal arrives while the session already
      holds a proposed or approved plan, that plan is
      {!Spice_protocol.Plan.supersede}d by the new id before saving. [now]
      supplies the proposal's creation and supersession timestamps. Resolution
      is a user decision applied through {!Artifacts.Plan.resolve} and submitted
      back as an ordinary answer. A proposal whose transition is rejected
      answers with a model-visible error instead of parking.
    - {b Goal.} A valid [update_goal] applies the model's complete/blocked
      report to the session's stored goal below [root] through
      {!Artifacts.Goal.update} and answers with the confirmation — including
      final token usage for a completed budgeted goal. Mode gating lives here: a
      report on a plan or review turn, on a session with no goal, or on a goal a
      user verb already moved (a state race) answers with a model-visible error
      before any mutation, so catalog absence is never the only enforcement.
    - {b Subagent.} Role gating ({!Spice_protocol.Mode.allows_role}) lives here:
      a spawn whose role [mode] forbids answers with a model-visible error
      without invoking [spawn]. An allowed spawn runs [spawn], which returns the
      model-visible summary ([Ok]) or a failure message ([Error]); either is
      wrapped into the tool result. The run-ledger and lineage bookkeeping live
      in [spawn], which captures the clock, store, and fresh child id the ledger
      needs.
    - {b Subagent wait/cancel.} A valid [wait_subagents] or [cancel_subagent]
      runs [wait]/[cancel] against the run registry; the returned text ([Ok]) or
      failure message ([Error]) is wrapped into the tool result. [wait] blocks
      the drain until the named runs settle.
    - {b Question.} An [ask_user] call — valid or not — returns [Ok None] so the
      turn parks on the answerable question boundary.
    - {b Other host tools.} A recognized host tool whose payload cannot be
      decoded answers with the model-visible decode error, so the model can
      correct its call.

    Calls that are not host tools are [Ok None]. *)
