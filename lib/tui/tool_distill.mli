(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Distilling a settled tool call into its transcript block (02-tools.md).

    The pure, state-free construction half of the tool grammar: given a tool
    call that has reached its result, produce the settled {!Tool_block.t} the
    document renders. {!Tool_block} owns the block type and its views; this
    module owns how a call becomes one. Every function is a total function of
    its inputs — no clock, no filesystem, no reducer state — so replay
    ({!Spice_protocol.Event.of_session}) lands the same block through the same
    path as a live turn. *)

val verb_of_name : string -> Tool_block.verb
(** [verb_of_name name] maps a tool's registered name to its {!Tool_block.verb},
    falling to {!Tool_block.Other} for a name with no 02-tools verb. Shared by
    the settle path and the live-tail running rows, which name a tool before it
    has a result. Re-audit the table whenever a tool is added, renamed, or
    removed. *)

val argument_of_call : Spice_llm.Tool.Call.t -> string
(** [argument_of_call call] is the header's primary argument, read off the
    call's typed input: the [@role — task] for a subagent spawn, the queried
    [path:line] for the OCaml navigation tools, the question for [ask_user], the
    generic first string field otherwise. Shared by the settle path and the
    live-tail running rows. *)

val of_tool_finished :
  Spice_session.Tool_claim.Started.t ->
  Spice_tool.Output.t Spice_tool.Result.t ->
  Tool_block.t
(** [of_tool_finished claim result] is the settled block for an executable tool
    call (edit, read, search, shell, the OCaml tools, …). Shell and Eval decide
    success from their {e output} status (a nonzero exit is [exited N] with the
    output tail), not the tool result; every other tool reads its verb-specific
    summary and disclosable detail off [result]. *)

val of_host_call :
  Spice_llm.Tool.Call.t -> Spice_llm.Tool.Result.t -> Tool_block.t
(** [of_host_call call result] is the settled block for a host-handled call,
    dispatched on the call's name: the todo board, the answered question, the
    subagent-management acts, plan/goal, and the generic done/failed row. *)

val denied : Spice_llm.Tool.Call.t -> Tool_block.t
(** [denied call] is the warning-dotted [denied] stub a permission refusal
    settles to the document, so the record shows the refused call (02-tools.md
    §Header). *)

val interrupted_call : Spice_llm.Tool.Call.t -> Tool_block.t
(** [interrupted_call call] is the warning-dotted [interrupted] stub a host call
    still pending at turn end settles to. *)

val interrupted_claim : Spice_session.Tool_claim.Started.t -> Tool_block.t
(** [interrupted_claim claim] is the warning-dotted [interrupted] stub a tool
    still running at turn end settles to. *)
