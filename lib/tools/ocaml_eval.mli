(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Fresh-process OCaml toplevel evaluator.

    [ocaml_eval] evaluates OCaml toplevel phrases in the selected Dune project
    directory. It first asks Dune for the toplevel load directives for that
    directory, then feeds those directives plus the requested phrases to a stock
    bytecode toplevel over standard input.

    The tool is intentionally not a persistent REPL. Every call starts from a
    fresh process, so previous calls cannot affect later typing or values. The
    evaluated OCaml code is arbitrary process execution: callers must treat this
    tool with the same care as a command runner. Every process is prepared by
    the required host sandbox after permission review; timeout, bounded output,
    and fresh process state remain independent resource controls. *)

val name : string
(** Stable tool name, ["ocaml_eval"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

module Input : sig
  type t
  (** Typed OCaml evaluation request. *)

  val make : ?dir:string -> ?timeout_ms:int -> string -> t
  (** [make code] evaluates [code] as OCaml toplevel phrase text.

      [dir], when present, is a workspace-relative path or an absolute path
      contained by the workspace. It must name a directory. The default is the
      workspace root. Dune loads local libraries under that directory using
      [dune ocaml top .].

      [timeout_ms], when present, is a total wall-clock budget for Dune setup
      and toplevel evaluation together, capped by {!Config.resolve_timeout_ms}.
      [code] is non-empty and must not contain NUL. If trimmed [code] does not
      end in [;;], the evaluator appends a phrase terminator.

      Raises [Invalid_argument] if [code] or [dir] is empty when supplied, if a
      string contains NUL, or if [timeout_ms <= 0]. Untrusted provider JSON
      should go through {!decode}. *)

  val code : t -> string
  (** [code t] is the requested phrase text before any terminator is appended.
  *)

  val dir : t -> string option
  (** [dir t] is the requested Dune directory, if explicit. *)

  val timeout_ms : t -> int option
  (** [timeout_ms t] is the requested total timeout, if explicit. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls. Unknown fields are
      rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

module Config : sig
  (** Host-controlled evaluation policy: executables, timeout bounds, per-stream
      output caps, and an environment overlay. *)

  type t
  (** Host-selected evaluation policy. *)

  val make :
    ?dune:string ->
    ?ocaml:string ->
    ?default_timeout_ms:int ->
    ?max_timeout_ms:int ->
    ?max_output_bytes:int ->
    ?environment:(string * string option) list ->
    unit ->
    t
  (** [make ()] is an evaluation policy.

      [dune] defaults to ["dune"]. [ocaml] defaults to ["ocaml"].
      [default_timeout_ms] defaults to [10_000]. [max_timeout_ms] defaults to
      [120_000]. [max_output_bytes] defaults to [65_536] per stream.
      [environment] is applied after deterministic non-interactive defaults.

      When Dune package management exposes [DUNE_OCAML_STDLIB], the evaluator
      prepends the corresponding compiler [bin] directory to [PATH] for child
      processes. This lets nested Dune projects find [ocamlc] in package-managed
      test and development sessions without requiring opam.

      Raises [Invalid_argument] if executable names or environment names are
      empty, if any string contains NUL, if an environment name contains ["="],
      if timeout bounds are non-positive, if the default timeout exceeds the
      maximum timeout, or if [max_output_bytes < 0]. *)

  val dune : t -> string
  (** [dune t] is the Dune executable used for setup. *)

  val ocaml : t -> string
  (** [ocaml t] is the OCaml toplevel executable used for evaluation. *)

  val default_timeout_ms : t -> int
  (** [default_timeout_ms t] is used when input omits [timeout_ms]. *)

  val max_timeout_ms : t -> int
  (** [max_timeout_ms t] is the largest accepted model-requested timeout. *)

  val max_output_bytes : t -> int
  (** [max_output_bytes t] is the retained byte budget for each output stream.
  *)

  val environment : t -> (string * string option) list
  (** [environment t] is the caller-supplied environment overlay. *)

  val resolve_timeout_ms : t -> int option -> (int, string) result
  (** [resolve_timeout_ms t timeout_ms] applies [t]'s timeout policy. *)
end

val permissions :
  sandbox:Spice_sandbox.t ->
  workspace:Spice_workspace.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~sandbox ~workspace input] declares the workspace read and
    model-authored OCaml code command needed to evaluate [input]. The command's
    exact identity includes its source, language, working directory, and the
    execution route proved by [sandbox]. Fixed Dune and OCaml argv remain sealed
    implementation details.

    If [dir] cannot be resolved inside [workspace] or sandbox enforcement was
    refused, the returned list is empty; {!run} reports the corresponding
    invalid-input or sandbox failure without opening a permission review. *)

module Output : sig
  type stage =
    | Dune_top
    | Eval
        (** The process phase whose status and streams are reported. [Dune_top]
            means setup failed before user code ran. [Eval] means Dune setup
            succeeded and the OCaml toplevel process ran. *)

  type stream =
    | Complete of string
    | Truncated of { head : string; tail : string; omitted_bytes : int }
        (** Captured process output stream. *)

  type status =
    | Exited of int
    | Signaled of int
    | Timed_out of { timeout_ms : int }
    | Cancelled
    | Failed_to_start of string  (** Process outcome for {!stage}. *)

  type t
  (** Typed OCaml evaluation evidence. *)

  val code : t -> string
  (** [code t] is the evaluated phrase text as requested, before any appended
      terminator. *)

  val dir : t -> Spice_workspace.Path.t
  (** [dir t] is the resolved Dune directory the toplevel ran in. *)

  val stage : t -> stage
  (** [stage t] is the process phase whose outcome is reported. *)

  val status : t -> status
  (** [status t] is the outcome of {!stage}. *)

  val stdout : t -> stream
  (** [stdout t] is the captured standard output stream. *)

  val stderr : t -> stream
  (** [stderr t] is the captured standard error stream. *)

  val duration_ms : t -> int
  (** [duration_ms t] is the elapsed wall-clock time in milliseconds. *)

  val timeout_ms : t -> int
  (** [timeout_ms t] is the effective timeout in milliseconds applied to the
      run. *)

  val max_output_bytes : t -> int
  (** [max_output_bytes t] is the retained byte budget for each output stream.
  *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed outputs to model-visible text and structured JSON,
      retaining the typed value as in-memory evidence. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] recovers typed evidence produced by {!encode}. *)
end

val run :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  config:Config.t ->
  ?watch:(unit -> string option) ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace ~config input] evaluates [input].

    [dir] is resolved through [workspace] and checked as an existing directory
    through [fs]. The implementation executes [dune ocaml top .] in that
    directory, writes Dune's directives plus [code] to the OCaml toplevel's
    standard input, and runs [ocaml -stdin -noinit] in the same directory.
    Standard output and standard error are drained concurrently and retained
    with head/tail bounds.

    [watch], when supplied, is polled before Dune is spawned: if it returns
    [Some endpoint] a live Dune watch holds the build lock, and [dune ocaml top]
    takes that same lock and fails fast rather than sharing it, so [run] returns
    a structured [`Unavailable] result naming the watch instead of spawning a
    doomed Dune process. [None] means no watch is detected and evaluation
    proceeds. The default is no predicate — today's behaviour.

    Non-zero exits, signals, timeouts, and failed starts return failed or
    interrupted tool results that still carry typed output when a process phase
    ran. [cancelled] defaults to a function returning [false]. *)

val tool :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  config:Config.t ->
  ?watch:(unit -> string option) ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ~config ()] is the erased {!Spice_tool.t} adapter. *)
