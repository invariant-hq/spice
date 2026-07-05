---
description: Guides systematic debugging of OCaml code — reproducing failures, getting usable backtraces, inspecting values without polymorphic print, and the OCaml-specific toolbox (project toplevel, ocamldebug time travel, logs, sanitizers). Use when investigating a bug, crash, wrong result, hang, unexpected exception, or a failing test with an unclear cause. Triggers on phrases like "debug this", "why is this failing", "no backtrace", "stack overflow", "segfault", "it hangs", "wrong result", or "can't reproduce".
---

# OCaml Debugging

Debugging is hypothesis-driven: reproduce, observe, localize, fix, lock in.
OCaml adds three specific frictions — backtraces are off by default and
easily destroyed, there is no polymorphic print for arbitrary values, and
the interactive debugger only runs bytecode. This skill is the workflow
plus the toolbox for working around all three.

Do not fix by guessing. A change made without a reproduction and an
observation is a new hypothesis, not a fix.

## 1. Reproduce First

Turn the report into one command that fails deterministically. In order of
preference: an existing failing test, a new minimal test, a toplevel
phrase, the real binary with fixed input.

- A property-test failure reports a seed — re-run with that seed
  (windtrap: `--seed N`) and debug the shrunk counterexample, which is
  the minimal input by construction.
- A flaky test is still information: suspect ordering, time, environment,
  or shared state, and capture more evidence (loop the test, log the
  variance) before touching code.
- The fastest hypothesis tester is a project-loaded toplevel (`dune utop`,
  or an eval tool when available): it prints any value with its type
  automatically, which sidesteps OCaml's no-polymorphic-print problem
  entirely.

## 2. Get a Backtrace Worth Reading

Backtraces are opt-in outside the toplevel:

- Run with `OCAMLRUNPARAM=b` or call `Printexc.record_backtrace true` at
  startup. Compile with `-g` — dune passes it by default in both dev and
  release profiles, so dune-built binaries are always backtrace-capable
  unless someone overrode the flags.
- **Re-raising destroys the trace.** A bare, immediate `raise e` in a
  handler is special-cased and preserves it, but doing any work first —
  cleanup, logging — overwrites the origin. The correct re-raise:

```ocaml
try f () with e ->
  let bt = Printexc.get_raw_backtrace () in
  cleanup ();
  Printexc.raise_with_backtrace e bt
```

- `raise_notrace` has no backtrace by design (flow-control exceptions);
  if a trace ends nowhere, check for it.
- For daemons and long-running processes, install
  `Printexc.set_uncaught_exception_handler`; `at_exit` has already run
  inside it, so flush your channels yourself.
- Read the trace from the raise point down. A trace bottoming out in a
  library you did not write usually means your callback raised inside it.

## 3. Make State Visible

- Prefer the printers that exist: `Format.eprintf "%a@." M.pp v`. The
  house convention of a `pp` per module pays off here; write a quick
  local one when missing rather than deriving ad-hoc string glue.
- Print to stderr and flush: `@.` (or `%!`) ends the line *and* flushes.
  "The print never ran" before a crash is usually an unflushed buffer,
  not dead code.
- Before adding printf, turn on the logging that is already there: with
  the logs library each module has its own source, so
  `Logs.Src.set_level` (or the app's verbosity flag) gives targeted
  debug output for one subsystem at no code cost.
- In the toplevel, `#trace f` prints every call and return of `f` with
  arguments — the fastest answer to "what is this function actually
  receiving".
- Instrumentation is temporary. Track every probe you add and remove
  them before finishing; promote only genuinely useful ones to
  `Log.debug`.

## 4. Classify the Failure

| Symptom | First move |
|---------|-----------|
| Wrong result, pure code | Reproduce in the toplevel, then bisect the pipeline with printed intermediates |
| Exception, no trace | Section 2: flags, re-raise sites, `raise_notrace` |
| `Stack_overflow` | Deep non-tail recursion; in OCaml 5 native raises reliably (own stacks; limit via `OCAMLRUNPARAM=l`, default ~1 GiB on 64-bit). Fix the recursion, don't raise the limit |
| Segfault / bus error | Almost always C stubs or unsafe access — load `ocaml-ffi`; run ASan/valgrind. Note: C stubs still use the system stack, so C-side overflow segfaults |
| Hang | Sample it: `perf top` (Linux) / `sample` (macOS) shows where it spins; a deadlock samples as idle waiting. magic-trace (Linux + Intel PT) captures the last moments before a trigger |
| Data race under domains | Build with a `-tsan` compiler variant (OCaml 5.2+) and re-run the repro; load `ocaml-concurrency` for the sharing rules |
| GC-correlated stalls | `olly gc-stats` / runtime-events tracing, not printf |
| Differs bytecode vs native, or by opt level | Suspect evaluation-order assumptions (argument order is unspecified), uninitialized values from stubs, or float-array representation |
| Heisenbug that vanishes with prints | Timing or GC sensitivity — switch from printf to logs or runtime events, which perturb less |

## 5. Interactive and Time-Travel Debugging

`ocamldebug` runs bytecode with breakpoints, stepping, value printing —
and **reverse execution**: run to the failure, then step *backwards* to
watch how the state got there. That inverts the usual pain of breakpoint
placement: break at the crash, not before it.

```
dune build ./bin/main.bc
ocamldebug _build/default/bin/main.bc
```

Limits worth knowing on OCaml 5: single domain only (it stops cleanly if
the program spawns a domain), stepping has quirks around effect handlers,
and replay is unavailable on native Windows. For everyday agent work the
toplevel and section 3 usually get there faster; reach for ocamldebug
when you need to inspect the sequence of states leading to a failure.

Native binaries: gdb/lldb work for post-mortem inspection (OCaml symbols
appear mangled as `camlModule.fn`); mainly useful for segfaults and C
stub issues.

## 6. Localize by Bisection

- History bisection: `git bisect run <repro-command>` finds the breaking
  commit unattended — worth it whenever the repro is scripted and the bug
  is a regression.
- Input bisection: shrink the failing input by halves; property-test
  shrinking automates exactly this.
- Code bisection: assert the invariant at the midpoint of the pipeline
  (`assert (Invariant.holds t)`) and move the probe toward the failing
  half — cheaper than reading everything.

## 7. Concurrency Notes

- Lwt loses backtraces across `Lwt.bind`/`let*` (exceptions are stored in
  promises and re-raised later). The `let%lwt` ppx preserves them via
  `backtrace_bind`; if a Lwt trace is useless, that is why.
- Eio fibers run on real stacks, so backtraces work normally. Use
  `Eio.traceln` for debug output — it does not switch fibers, so it will
  not reorder the bug away.
- For domain races, reproduce under TSan before reasoning from the code:
  the memory model will surprise intuition less than a reported race.

## 8. Fix and Lock It In

- Fix the root cause, not the symptom the probe happened to show.
- Write the failing test before the fix, watch it fail, fix, watch it
  pass (load `ocaml-testing` for placement and style). A bug that got
  through once will get through again without a regression test.
- Remove all temporary instrumentation; keep only what earned a place
  behind `Log.debug`.

## Checklist

- [ ] Failure reproduced by one deterministic command (seed pinned for
      property tests) before any code change
- [ ] Backtraces enabled (`OCAMLRUNPARAM=b` / `record_backtrace`), and
      re-raise sites use `raise_with_backtrace`
- [ ] State observed through existing `pp` printers, logs sources, the
      toplevel, or `#trace` — with output flushed (`@.`)
- [ ] Failure classified (section 4) and the matching tool used, not
      generic print-spraying
- [ ] Cause localized by bisection (history, input, or invariant), not
      by reading everything
- [ ] Root cause fixed; failing-first regression test added
- [ ] All temporary probes removed; useful ones promoted to `Log.debug`
