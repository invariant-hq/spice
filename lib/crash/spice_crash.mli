(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Process-wide fault handling: exception backtraces, crash-report
    persistence, and terminal-safe signal breadcrumbs.

    spice runs its interactive UI on the alternate screen in raw mode, so a
    fault that ends the process must leave a durable trace or it is invisible:
    the terminal is restored and any one-line message scrolls past behind the
    returning shell prompt, and a terminating signal prints nothing at all. This
    module owns that trace. {!install} runs once at process start; the
    interactive frontend additionally calls {!install_signal_breadcrumbs} once
    it owns the terminal, and {!record} persists faults it recovers from without
    ending the process. *)

val install : report_dir:string -> context:string -> unit
(** [install ~report_dir ~context] enables exception backtraces
    ({!Printexc.record_backtrace}) and installs the uncaught-exception handler.
    On an exception that reaches the top level the handler writes a crash report
    under [report_dir], prints a one-line summary and the report path to
    [stderr] — by then the frontend's switch has restored the terminal, so the
    line is visible — and exits [125], the status spice documents for an
    unexpected internal error. [context] heads every report (typically the
    version and subcommand). The handler prints, so it is sound only once the
    terminal is no longer UI-owned; {!record} is the print-free variant for
    faults handled while the UI is up. Idempotent: later calls are ignored. *)

val install_signal_breadcrumbs : on_restore:(unit -> unit) -> unit
(** [install_signal_breadcrumbs ~on_restore] installs handlers for the catchable
    terminating signals (SIGINT, SIGTERM, SIGQUIT, SIGHUP, SIGABRT). On delivery
    a handler runs [on_restore] (best effort — leaving the alternate screen so
    the breadcrumb below is visible), writes a crash report naming the signal,
    prints the breadcrumb, and exits [128 + signum]. SIGSEGV and SIGBUS are left
    to the runtime (stack-overflow detection and core dumps); SIGPIPE is already
    ignored by the Eio backend. A no-op unless {!install} ran first (there is no
    report directory to record against otherwise). Intended for the frontend
    that owns the real terminal. *)

val record : fault:string -> detail:string -> string option
(** [record ~fault ~detail] writes a crash report (heading, the [fault] line,
    and [detail] body — typically a backtrace) under the report directory from
    {!install} and returns its path, or [None] when no report could be written
    (including when {!install} never ran). It prints nothing, so it is safe to
    call while the UI owns the terminal: the caller surfaces the fault its own
    way (an in-UI failure notice, a log line) and uses this only for the durable
    record. *)
