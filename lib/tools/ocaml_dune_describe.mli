(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-facing Dune project description tool.

    [ocaml_dune_describe] runs [dune describe workspace] and
    [dune describe tests] as one-shot process calls, then returns the normalized
    {!Spice_ocaml.Project.t}. It does not use Dune RPC, does not depend on a
    running Dune watcher, and does not share state with the proactive
    diagnostics watcher.

    The tool is the project-shape companion to {!Ocaml_dune_diagnostics}: use
    this module for libraries, executables, compilation units, dependencies, and
    tests; use diagnostics for the current build errors and warnings. *)

val name : string
(** Stable tool name, ["ocaml_dune_describe"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

module Output : sig
  type t
  (** The typed output retained by completed [ocaml_dune_describe] calls. *)

  val project : t -> Spice_ocaml.Project.t
  (** [project t] is the normalized project returned by Dune describe. *)

  val component_count : t -> int
  (** [component_count t] is the number of described project components. *)

  val test_count : t -> int
  (** [test_count t] is the number of described Dune tests. *)

  val freshness : t -> Spice_ocaml_dune.Project_source.Freshness.t option
  (** [freshness t] is the build-lock freshness evidence when the describe was
      routed through a {!Spice_ocaml_dune.Project_source.t}, and [None] for a
      direct describe (no source). It records whether the project shape was a
      fresh run or the boot snapshot, and if a snapshot, whether it has drifted
      and which watch holds the lock. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is [Some t] if [output] was produced by this tool
      and retained typed evidence, and [None] otherwise. *)
end

val permissions : Spice_workspace.t -> Spice_permission.Request.t list
(** [permissions workspace] are the read and executable permissions required to
    run the Dune describe commands for [workspace]. *)

val run :
  sandbox:Spice_sandbox.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  Spice_tool.Context.t ->
  unit ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~process_mgr ~clock ~cwd ~workspace ctx ()] runs the describe commands
    in [cwd].

    With [project_source] the describe is resolved fresh-or-snapshot with
    build-lock awareness (see {!Spice_ocaml_dune.Project_source}); the output
    carries {!Output.freshness} evidence, and a lock-held-with-no-snapshot state
    fails as [`Unavailable] naming the watch instead of a raw command failure.
    Without it the describe runs directly in [cwd], byte-identical to prior
    behaviour (no freshness field).

    The result is completed with {!Output.t} on successful parsing, interrupted
    if [ctx] is cancelled, and failed with a Dune adapter error message if a
    command exits unsuccessfully, times out, or the describe output cannot be
    decoded. *)

val tool :
  sandbox:Spice_sandbox.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~process_mgr ~clock ~cwd ~workspace ()] is the erased model-facing
    tool for {!run}. *)
