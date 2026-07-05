(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace shell command runner.

    [Shell] runs one non-interactive shell command in a workspace-resolved
    directory. It is an escape hatch for build, test, package-manager, Git, and
    diagnostic commands; ordinary file reads, searches, listings, and edits
    should use the dedicated host tools because they produce tighter typed
    evidence.

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions};
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.
    Process execution and sandbox preparation are private implementation details
    of [spice_tools]. Restricted sandbox requests fail closed when the host
    cannot enforce them; unconfined configuration is the explicit escape hatch.
*)

val name : string
(** Stable tool name, ["shell"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

(** {1 Input} *)

module Input : sig
  type t
  (** Typed shell command request.

      [Input.t] is the host-side request type. Build values directly with
      {!make}, or decode provider JSON with {!decode}. *)

  val make :
    ?workdir:string ->
    ?timeout_ms:int ->
    ?description:string ->
    ?escalate:bool ->
    string ->
    t
  (** [make command] runs [command] through the host-configured shell.

      [command] is non-empty shell text. [workdir], when present, is a
      workspace-relative path or an absolute path contained by the workspace;
      absent [workdir] means the workspace root. [timeout_ms], when present, is
      capped by {!Config.resolve_timeout_ms}. [description] is optional
      reviewer/UI metadata and has no execution semantics.

      [escalate] (default [false]) requests running this one command outside the
      sandbox. It is a request, never a grant: under workspace-write shaped
      confinement it raises a reviewable permission access; under read-only
      confinement {!run} refuses the input; under unconfined or
      declared-external decisions it changes nothing.

      Raises [Invalid_argument] if [command], [workdir], or [description] is
      empty when supplied, if any string contains NUL, or if [timeout_ms <= 0].
      Untrusted provider JSON goes through {!decode}, which reports the same
      invalid states as decode errors. *)

  val command : t -> string
  (** [command t] is the requested shell command text. *)

  val workdir : t -> string option
  (** [workdir t] is the requested working directory, if explicit. *)

  val timeout_ms : t -> int option
  (** [timeout_ms t] is the requested timeout, if explicit. *)

  val description : t -> string option
  (** [description t] is optional reviewer/UI metadata. *)

  val escalate : t -> bool
  (** [escalate t] is whether the input requests per-command escalation. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible fields are [command], optional [workdir], optional
      [timeout_ms], optional [description], and optional [escalate]. Unknown
      fields are rejected. Output budget, shell selection, sandboxing, and
      environment policy are host configuration, not model input; [escalate] is
      a request subject to permission review, never a grant. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

(** {1 Configuration} *)

module Config : sig
  type t
  (** Host-selected shell execution policy.

      Configuration is immutable. It owns the shell executable, the sealed
      sandbox decision, deterministic environment overlay, timeout bounds, and
      retained output budget. The environment passed to the child starts from
      the process environment filtered by the sandbox decision, then applies
      deterministic non-interactive defaults, then the caller overlay. *)

  val make :
    ?shell:string ->
    ?sandbox:Spice_sandbox.t ->
    ?default_timeout_ms:int ->
    ?max_timeout_ms:int ->
    ?max_output_bytes:int ->
    ?environment:(string * string option) list ->
    unit ->
    t
  (** [make ()] is a shell execution policy.

      [shell] defaults to the platform's ordinary non-interactive shell.
      [sandbox] is the host-sealed spawn decision; it defaults to a confined
      read-only request sealed without a backend, so the zero-configuration
      shell refuses every command. The host resolves modes, backends, and gates
      and passes authority in; sandbox policy is never model input.
      [environment] is an overlay applied after the built-in deterministic
      non-interactive environment. A binding [(name, Some value)] sets [name];
      [(name, None)] removes [name].

      Raises [Invalid_argument] if [shell] or an environment name is empty, if
      an environment name contains ["="], if any string contains NUL, if timeout
      bounds are non-positive, if the default timeout exceeds the maximum
      timeout, or if [max_output_bytes < 0]. *)

  val shell : t -> string
  (** [shell t] is the shell executable used to run commands. *)

  val sandbox : t -> Spice_sandbox.t
  (** [sandbox t] is the sealed sandbox decision. *)

  val default_timeout_ms : t -> int
  (** [default_timeout_ms t] is the timeout used when an input omits one. *)

  val max_timeout_ms : t -> int
  (** [max_timeout_ms t] is the largest accepted model-requested timeout. *)

  val max_output_bytes : t -> int
  (** [max_output_bytes t] is the retained byte budget for each output stream.
  *)

  val environment : t -> (string * string option) list
  (** [environment t] is the caller-supplied environment overlay.

      The implementation also applies deterministic non-interactive defaults,
      such as disabling pagers and color, before this overlay. *)

  val resolve_timeout_ms : t -> int option -> (int, string) result
  (** [resolve_timeout_ms t timeout_ms] applies [t]'s timeout policy.

      [None] resolves to {!default_timeout_ms}[ t]. [Some timeout_ms] errors if
      it is non-positive or greater than {!max_timeout_ms}[ t]. *)
end

val permissions :
  workspace:Spice_workspace.t ->
  config:Config.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~workspace ~config input] are the command permission requests
    for [input].

    The tool may parse simple shell command sequences into structured
    {!Spice_permission.Access.Command.Argv} accesses for better review evidence.
    When parsing is ambiguous, it requests one conservative
    {!Spice_permission.Access.Command.Shell} access for the whole command.
    Security must not depend on this parser; sandboxing and host policy remain
    the execution boundary.

    An escalating input under workspace-write shaped confinement additionally
    requests one extension access named ["shell.escalate"] whose subject is the
    command text, so policies and reviewers decide escalation separately from
    ordinary shell execution and session grants never broaden beyond the exact
    command.

    If [workdir] cannot be resolved inside [workspace], the returned list is
    empty; {!run} reports the resolution failure as an invalid-input tool
    result. Directory existence and kind checks happen during {!run}. *)

(** {1 Output} *)

module Output : sig
  type stream =
    | Complete of string
    | Truncated of { head : string; tail : string; omitted_bytes : int }
        (** Captured process output stream.

            [Complete text] means the full stream was retained. [Truncated]
            retains the beginning and end of the stream and reports the number
            of bytes omitted between them. *)

  type status =
    | Exited of int
    | Signaled of int
    | Timed_out of { timeout_ms : int }
    | Cancelled
    | Failed_to_start of string
        (** Process outcome.

            [Exited code] is the shell process exit code. [Signaled signal]
            means the process group ended because of [signal]. [Timed_out _] and
            [Cancelled] are terminal outcomes after the implementation has
            attempted to terminate the process group. [Failed_to_start message]
            reports host-side setup or spawn failure before the command ran. *)

  type t
  (** Typed command execution evidence. *)

  val command : t -> string
  (** [command t] is the executed shell command text. *)

  val workdir : t -> Spice_workspace.Path.t
  (** [workdir t] is the resolved workspace working directory. *)

  val status : t -> status
  (** [status t] is the process outcome. *)

  val stdout : t -> stream
  (** [stdout t] is the retained standard output evidence.

      Stream contents are process bytes represented as OCaml strings; the tool
      does not validate UTF-8. *)

  val stderr : t -> stream
  (** [stderr t] is the retained standard error evidence.

      Stream contents are process bytes represented as OCaml strings; the tool
      does not validate UTF-8. *)

  val duration_ms : t -> int
  (** [duration_ms t] is the observed wall-clock runtime in milliseconds. *)

  val timeout_ms : t -> int
  (** [timeout_ms t] is the effective timeout applied to the command. *)

  val max_output_bytes : t -> int
  (** [max_output_bytes t] is the retained byte budget for each output stream.
  *)

  val enforcement : t -> Spice_sandbox.Evidence.t
  (** [enforcement t] is the sandbox enforcement evidence; see
      {!Spice_sandbox.Evidence}. *)

  val description : t -> string option
  (** [description t] is the optional input description. *)

  type render
  (** Model-visible text rendering policy. *)

  val compact : render
  (** [compact] renders command, working directory, status, duration, sandbox
      evidence, and retained stdout/stderr previews. *)

  val verbose : render
  (** [verbose] renders the same evidence as {!compact}, with fuller stream
      truncation metadata for debugging. *)

  val encode : ?render:render -> t Spice_tool.Output.encoder
  (** [encode ?render] projects typed shell outputs to model-visible tool
      output.

      The JSON projection preserves command, workdir, status, duration,
      effective limits, sandbox evidence, and structured stdout/stderr stream
      retention. The text projection is compact and stable, and does not hide
      non-zero exits, timeouts, cancellations, or truncation.

      [render] defaults to {!compact}. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}. *)
end

(** {1 Execution} *)

val run :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  config:Config.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~fs ~workspace ~config input] executes a typed shell command and
    returns typed output.

    [workdir] is resolved through [workspace] and checked through [fs]. The
    command is spawned as one non-interactive shell invocation using
    {!Config.shell}[ config]. Standard input is closed or connected to an empty
    input stream. The implementation applies deterministic non-interactive
    environment defaults, drains stdout and stderr concurrently, enforces
    {!Config.resolve_timeout_ms}, and retains head/tail output evidence bounded
    by {!Config.max_output_bytes}.

    A restricted sandbox request that cannot be enforced returns a failed tool
    result with {!Spice_sandbox.Evidence.refused} evidence and does not spawn
    the command. Non-zero exits, signals, timeouts, and failed starts return
    failed or interrupted tool results that still carry typed output evidence
    when the command reached the execution phase.

    On timeout or cancellation, the implementation attempts to terminate the
    command's process group, not only the direct shell process. [cancelled]
    defaults to a function returning [false]. *)

(** {1 Adapter} *)

val tool :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  config:Config.t ->
  ?render:Output.render ->
  unit ->
  Spice_tool.t
(** [tool ~fs ~workspace ~config ()] is the erased {!Spice_tool.t} adapter.

    [render] defaults to {!Output.compact}. *)
