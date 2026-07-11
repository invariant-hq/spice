(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Bounded argv process execution for host tools.

    [Process] runs an executable directly with an argument vector. It does not
    invoke a shell. The runner drains stdout and stderr concurrently, enforces
    independent byte limits for each stream, and terminates the child when the
    call is cancelled or a stream exceeds its bound.

    Sandboxed callers use {!run_sandboxed} or {!run_sandboxed_shell}.
    {!run_shell} accepts an already prepared invocation for the shell tool's
    explicit escalation path. *)

type status =
  | Exited of int
  | Signaled of int
  | Cancelled
  | Timed_out of { timeout_ms : int }
  | Output_exceeded of string
  | Failed of string
  | Refused of Spice_sandbox.Error.t
      (** Process outcome.

          [Output_exceeded stream] names the stream that exceeded its configured
          byte limit, currently ["stdout"] or ["stderr"]. [Failed] describes a
          host-side failure to start or supervise the child. *)

type result = { status : status; stdout : string; stderr : string }
(** Completed process result.

    [stdout] and [stderr] contain the bytes collected before the process
    stopped. The strings are process bytes, not guaranteed UTF-8 text. When
    [status] is [Output_exceeded _], the exceeding stream is a bounded prefix.
*)

type captured =
  | Complete of string
  | Truncated of { head : string; tail : string; omitted_bytes : int }
      (** Head/tail bounded stream capture for shell-style process evidence.

          The retained [head] and [tail] are process bytes. [omitted_bytes]
          counts bytes dropped between them. *)

type shell_status =
  | Shell_exited of int
  | Shell_signaled of int
  | Shell_timed_out of { timeout_ms : int }
  | Shell_cancelled
  | Shell_failed_to_start of string
  | Shell_refused of Spice_sandbox.Error.t
      (** Shell process status.

          [`Timed_out _] and [`Cancelled] are reported after the runner has
          attempted to terminate the spawned process group. [`Failed_to_start _]
          reports setup, fork, or exec failure before the requested command
          could run. *)

type shell_result = {
  shell_status : shell_status;
  shell_stdout : captured;
  shell_stderr : captured;
  shell_duration_ms : int;
}
(** Completed shell-style process result. *)

val run :
  ?stdout_limit:int ->
  ?stderr_limit:int ->
  timeout_ms:int ->
  cancelled:(unit -> bool) ->
  string list ->
  result
(** [run argv] executes [argv] as a direct process invocation.

    [argv] must contain the executable name followed by its arguments. An empty
    [argv] returns [Failed]. [cancelled] is polled while the child is running,
    and [timeout_ms] bounds the complete wait. [stdout_limit] and
    [stderr_limit] default to conservative bounded values.

    Raises [Invalid_argument] if either limit is negative or [timeout_ms] is not
    positive. *)

val run_shell :
  cwd:string ->
  env:string array ->
  timeout_ms:int ->
  max_output_bytes:int ->
  ?stdin:string ->
  cancelled:(unit -> bool) ->
  string list ->
  shell_result
(** [run_shell ~cwd ~env ~timeout_ms ~max_output_bytes ?stdin argv] executes
    [argv] with shell-tool semantics.

    [cwd] must be an existing directory path selected by the caller. [env] is
    the exact process environment. [argv] is executed directly and normally
    contains the configured shell plus its non-interactive command arguments.
    When [stdin] is supplied, the runner writes it to the child's standard input
    and closes the stream. Otherwise the child's standard input is [/dev/null].
    The runner captures head/tail output for stdout and stderr independently.

    On Unix, the child is placed in its own process group before [exec] where
    possible. Cancellation and timeout signal that process group with [SIGTERM],
    then [SIGKILL] if it is still present.

    Raises [Invalid_argument] if [cwd] is empty, [timeout_ms <= 0], or
    [max_output_bytes < 0]. *)

val run_shell_fd :
  cwd:Unix.file_descr ->
  env:string array ->
  timeout_ms:int ->
  max_output_bytes:int ->
  ?stdin:string ->
  cancelled:(unit -> bool) ->
  string list ->
  shell_result
(** [run_shell_fd ~cwd] has {!run_shell}'s execution semantics but changes the
    child into the already-open directory [cwd] with [fchdir] before [exec].

    The caller retains ownership of [cwd] and must keep it open until this call
    returns. Binding execution to a directory descriptor prevents replacement
    of its pathname between validation and child startup. *)

val prepare :
  sandbox:Spice_sandbox.t ->
  env:string array ->
  string list ->
  (string list * string array, Spice_sandbox.Error.t) Stdlib.result
(** [prepare ~sandbox ~env argv] is the exact argv and environment selected by
    [sandbox] for [argv]. An empty argv and a sandbox refusal are errors. *)

val run_sandboxed :
  ?stdout_limit:int ->
  ?stderr_limit:int ->
  sandbox:Spice_sandbox.t ->
  timeout_ms:int ->
  cancelled:(unit -> bool) ->
  string list ->
  result
(** [run_sandboxed ~sandbox ~timeout_ms argv] prepares [argv] through [sandbox]
    before executing it with {!run}'s bounded direct-process semantics. A
    refusal is returned as [Refused] and starts no process. *)

val run_sandboxed_shell :
  sandbox:Spice_sandbox.t ->
  cwd:string ->
  env:string array ->
  timeout_ms:int ->
  max_output_bytes:int ->
  ?stdin:string ->
  cancelled:(unit -> bool) ->
  string list ->
  shell_result
(** [run_sandboxed_shell ~sandbox ~cwd ~env argv] prepares [argv] and the exact
    [env] through [sandbox] before executing it with {!run_shell}'s timeout,
    cancellation, process-group, and bounded-output semantics. A refusal is
    returned as [Shell_refused] and starts no process. *)
