# Fault handling

Developer reference for how Spice surfaces and contains failures: what
happens on an uncaught exception or terminating signal, which faults are
deliberately non-fatal, and the policy behind both. User-facing toolchain
diagnostics live in the manual (`doc/manual/configuration.md`, "OCaml
toolchain resolution").

## Policy

- **Backtrace recording is application policy, never a library's.**
  `bin/main.ml` sets `Printexc.record_backtrace true` at entry — one line,
  covering headless commands and the TUI (dune makes the same call for
  itself in `dune_engine`). Libraries must not flip process-global runtime
  knobs: matrix briefly forced recording on and the call was removed
  upstream; its handler now reports whatever was recorded and, when
  recording is off, says how to enable it (`OCAMLRUNPARAM=b`).
- **Fix faults at their source; do not wrap them in apparatus.** The Linux
  silent-crash episode (2026-07) was matrix discarding the backtrace it was
  handed. The first fix built a spice-side crash library — report files
  under the config home, custom signal handlers, an exit-code convention —
  and was removed the same day in favor of the eight-line upstream fix.
  Do not reintroduce a crash-file/signal apparatus in spice.

## The fatal path

matrix owns the uncaught-exception handler and the terminating-signal
handlers (SIGTERM/SIGINT/SIGQUIT/SIGABRT) while a TUI runs. On an uncaught
exception the shutdown handlers restore the terminal, then
`Printexc.default_uncaught_exception_handler` prints the exception and its
backtrace on the normal screen. Headless commands get the stock OCaml
report, with a backtrace because recording is on. Uncatchable faults
(SIGKILL, OOM kills) stay uncatchable; diagnose those from the shell
(`echo $?`, `dmesg`).

## Non-fatal seams

One background failure must not tear down a session. Faults are routed into
a recovery seam instead of escaping to the shared switch:

| Seam | Behavior on fault |
| --- | --- |
| TUI effect thunk (`lib/tui/runtime.ml`) | Logs and drops that one effect; `Cancelled` re-raises for teardown. |
| Turn drain (`lib/host/live.ml`) | Non-cancellation exceptions become `Error (Internal ...)`, settling the turn as a failure notice in the transcript. |
| Watcher probes (`lib/host/watchers.ml`) | `bounded` degrades the probe on any non-cancellation fault. |
| Session store | A document/session id mismatch is `Error.Corrupt`, reported, never raised. |

When adding background work, route its failures into one of these seams (or
an equivalent logged degradation) rather than letting an exception escape a
fiber into the switch: an escaping exception ends the whole TUI, which is
exactly the class of field failure this design exists to prevent.
