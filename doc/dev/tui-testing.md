# Deterministic TUI tests

Developer reference for the in-process TUI test suite at `test/tui`. It
drives the real application — `App.init/update/view/subscriptions`, the real
runtime command interpreter, the real host and session store, the real provider
wire protocol — through the same event vocabulary a terminal produces, and
observes the rendered cell grid. The application is not launched in a terminal
subprocess or pty; the fake provider runs in-process. Tools may still launch real
subprocesses, and the scheduler uses short real-clock breaths to let genuine IO
complete. Application-visible time remains virtual and test-controlled.

This is the operational contract: how the harness stays deterministic, which
boundary belongs in which suite, and what breaks determinism. The harness itself
is `test/tui/harness/`.

Both test boundaries use the single wrapped `tui_harness` library. Its public
surface is deliberately small:

- `Project`, `Key`, and `Screen` provide shared fixtures and assertions;
- `Provider_script` describes requests and replies once for both interpreters;
- `Tui` drives the deterministic in-process application;
- `Pty` drives a real process and terminal emulator;
- `Provider_process` runs the external fake provider needed by PTY tests.

The Eio provider runtime and low-level PTY implementation remain private to the
library. PTY test executables live under `test/tui/pty/`; application tests stay
directly under `test/tui/`.

## Choose the test boundary

| Boundary under test | Home |
| --- | --- |
| Application state, rendering, input decoding, provider turns, dialogs, session persistence, tool execution, resize/reflow | `test/tui/` |
| Raw-mode and alternate-screen setup/restore, primary-screen goodbye output, real `SIGWINCH`, OSC title emission, CLI launch wiring, and a real Dune-watch handshake | `test/tui/pty/` |
| CLI argument resolution, exit codes, and real OS-sandbox enforcement | Cram/black-box tests |

`Tui.await_exit` and `Tui.outcome` verify that the in-process application exits
and returns the expected product outcome. They cannot observe bytes written to
the primary screen after the alternate screen closes, terminal modes, signals,
or whether the CLI launched the application correctly. Keep at least one real
process test for those contracts.

A real Dune RPC/watch handshake also crosses the process boundary. The
in-process suite may test the TUI's response through an injected or controlled
seam, but it does not replace a smoke test that proves connection to a real
`dune build --watch` process.

## The model

The app runs under `Spice_tui.run` with its environment swapped through public
seams: a headless `Matrix_test` backend (mosaic's `matrix.test`), one virtual
clock, a pinned process-environment snapshot, and one composable
`Mosaic.Probe.t`. Mosaic contributes message, perform, and render checks; Spice
adds main-session work through settlement and child-run drains to that same
value. The Mosaic loop runs in one Eio fiber and parks
in the backend's `on_idle`; the test script runs in another. A test:

- **drives** with `Tui.keys` / `Tui.enter` / `Tui.paste` / `Tui.resize` (raw
  bytes through the real input parser, so decode regressions stay covered);
- **waits** with `Tui.settle` (quiescence) or `Tui.advance dt` (virtual time) —
  never a sleep, never a substring-with-deadline;
- **gates** the provider with `Tui.await_request` / `Tui.release` (a held reply
  is a named `Eio.Promise`, so a mid-flight state is observable for exactly as
  long as the test needs); uses `Tui.await_suspend` when a tool-call response
  opens a dialog, and `Tui.settle_turn` when a keystroke ends an in-flight turn;
- **waits at special boundaries** with `Tui.settle_pending_perform` for an auth
  challenge whose perform intentionally stays open, and
  `Tui.await_review_refresh` for the real watcher wake plus virtual debounce;
- **asserts** a full 24-row frame via `Tui.print` at a pinned size (default
  80×24). Substring facts are forbidden; a frame is a `[%expect]` golden,
  promoted with scoped `dune promote test/tui/<file>`.

Time only moves when the test moves it. Ages, elapsed counters, spinner phase,
and session-id stamps are deterministic functions of test-controlled time, so
they may appear verbatim in goldens.

## The virtual-clock contract

The suite is deterministic only because the virtual clock is the single source
of time and *nothing advances it behind the test's back*. Four invariants hold
that line. Each was violated at least once, and each violation reappeared as a
hang or a flake — treat them as load-bearing.

- **One-shot redraws render at the current instant, never by advancing the
  clock.** The mosaic test backend is created with `~pace_redraws:false`
  (`matrix.test`). Under a real clock, `request_redraw` coalesces an event storm
  to `target_fps` by *waiting out* the frame interval — free, because wall time
  passes anyway. Under a virtual clock that "wait" is an advance the harness did
  not ask for, and it moves the very clock `Sub.every` timers read: a held
  turn's working-line spinner (`app.ml` fires `spinner + 1` and
  `now +. turn_tick_interval` together) then ticks a non-deterministic number of
  times during a settle. With pacing off, a one-shot renders immediately and the
  clock does not move.

- **A settle never steps time.** `settle_from`'s "messages/redraw pending at
  park" branch wakes the loop (`round_trip`) and re-settles — it must not
  `set_time`. Async work (a provider fiber dispatching) can land a message or a
  redraw between the loop parking and the harness observing it; the backend
  renders that at the current instant, so no cadence-flush advance is needed.
  Advancing there marched the spinner a frame per landing (the `⠙`/`⠹`
  mid-flight flake). `settle` also does **not** quantize to the next whole
  second — that was there to erase sub-second render drift the old backend
  produced, drift the current backend no longer has.

- **Live animation is the only thing the backend auto-advances.** When a
  `Sub.on_tick` animation holds the render cadence (reduced motion off), the
  backend advances its virtual now to the frame deadline in `read_events` so
  `on_idle` observes a presented frame. This is the one place virtual time moves
  without the script; it is bounded to a frame interval and only fires while
  `loop_active`. Reduced motion is the harness default precisely so most tests
  sit in the idle regime where waiting consumes zero virtual time; opt back in
  per test with `~env:[ ("SPICE_REDUCED_MOTION", "0") ]` when the animation *is*
  the behaviour under test.

- **The epoch is small on purpose.** `epoch = 1000.` in `tui.ml`, not a real
  Unix timestamp. The runtime and mosaic pace off sub-second intervals (0.1 s
  and finer); at a real-epoch magnitude (~1.7e9) those intervals fall below the
  float ULP, so `last +. interval -. now` and `now -. last >= interval` disagree
  at the boundary and a cadence check stalls the loop. A small base keeps the
  arithmetic exact. Nothing in the suite renders an absolute wall-clock date, so
  the base is free to be small.

Two of these are mosaic invariants, enforced there: `Matrix.pace_redraws` (the
config flag) and `Mosaic.Sub.every` firing within a float slack when a frame
lands exactly on a timer deadline (a strict `>=` on accumulated-float deltas
skips the fire and busy-loops). `mosaic/test/loop/test_loop.ml` guards the
timer case directly.

## The environment contract

**The environment a run's app sees is a function of that run's own parameters —
never of the runs before it in the same executable.**

Time is not the only thing that leaks between runs. `Project.apply` pins names
with `Unix.putenv` and never restores them, so a name one run sets is still set
for the next. That is harmless for the names *every* run pins, and a
determinism bug for the conditional ones: `OPENAI_API_KEY` is added only for a
run with a provider script, and `SPICE_PERMISSION_MODE` only where a test asks
for it.

The failure is quiet, and it does not look like an environment bug. A
provider-less run that inherits a credential sees a connected account and
renders the *logged-in* stage — no account line, no login nudge, and the whole
stage one row lower, because a shorter workspace block re-centers. That frame
reads exactly like a layout bug, and it was investigated as one. The same leak
had rewritten goldens across the suite: auth frames asserting `env
OPENAI_API_KEY still active` in tests that set no key, and tool frames showing
`permission: auto edits` under the default posture.

`Project` therefore records every name `apply` pins, and `env_snapshot` and
`env_array` subtract the pinned names this run does not override. This needs no
list of which bindings are conditional, so the next one added is covered, and
it keeps a developer's own exported keys out of the frames too.

The rule for reading a suspicious golden follows from this: **before chasing a
layout bug, check whether the frame is rendering a state the test never asked
for.** A run's frame should be explicable from its own `~env`, `~provider`, and
`~seed` alone.

## Settle and advance

- `settle` blocks until the backend is parked, the one probe reports no pending
  Mosaic or Spice work, no redraw is queued, and a short scheduler drain turns
  up nothing new. Work parked on a **held** provider gate counts as settled —
  that held mid-flight state is exactly what a test observes. It carries a loud
  budget; it never hangs or advances virtual time.
- `advance dt` steps virtual time forward by `dt` in cadence-sized steps, firing
  due `Sub.every` / `Sub.on_tick` timers, then settles without quantizing.
  Elapsed counters tick exactly `dt`; ages age exactly `dt`.
- `await_request n` pumps (settle + a 1 ms real breath) until the n-th request
  reaches the in-process provider, then returns its body. It fails loudly rather
  than hanging.

## Provider scripts and asynchronous boundaries

Provider scripts are ordered by default: request N must match script item N.
Use `~unordered:true` only when genuinely concurrent callers, such as a parent
and detached subagents, can arrive in either order. Every unordered item needs
content expectations that distinguish it from every other pending item; the
first matching item is consumed.

The provider supports ordinary completions, held streaming completions, one or
several tool calls, and plain HTTP responses. Choose the synchronization helper
for the transition being observed:

- After `Tui.await_request`, a named provider gate keeps a mid-flight frame
  stable. `Tui.release` waits for the main-session settlement and
  settles the resulting frame. No provider counter or spinner-state proxy is
  involved.
- After a tool-call request that should suspend into a question or permission
  dialog, call `Tui.await_suspend`. It settles against the same Live-aware probe,
  so the dialog is rendered only after the drain reaches its waiting boundary.
- After a force-interrupt or another keystroke that ends a turn while its
  provider gate remains held, call `Tui.settle_turn`. A plain settle is allowed
  to stop at the deliberately held `Interrupting…` state; `settle_turn` waits
  specifically for the main-session check before settling the frame.

These helpers move no virtual time. Do not use `Tui.advance` as an async-work
barrier: it changes elapsed counters and spinner state and can trigger unrelated
time-dependent work.

The only real-clock sleep in the harness is a 1 ms scheduler breath while real
IO (localhost HTTP, tool subprocesses, fswatch systhreads) is genuinely in
flight; park-waiting is condition-based, not polled.

## Writing a test

- **Full frames, pinned size.** `Tui.print` prints the whole 80×24 grid,
  normalized (`$PROJECT`, `ses_$ID`). Assert the frame, not a line.
- **Batch scenarios that share state into one `Tui.run`** — a boot is ~60 ms.
  `test_turn` prints three frames (working, ticked, settled) from one boot.
  Don't contort unrelated scenarios together.
- **Give every `Tui.run ~name` a globally unique value across the suite.** The
  temporary project is `/tmp/spice-tui-<name>` and is cleared at startup;
  duplicate names in concurrently running executables can delete each other's
  workspace and session store.
- **Send Enter as its own write** (`Tui.enter`), never `"/cmd\r"` in one chunk.
- **Reduced motion and workspace tooling are off by default**; opt in per test
  with `~env` only when the animation or the dune footer is the behaviour under
  test (workspace tooling on spawns a real `dune`, so initial readiness depends
  on host scheduling).
- Non-visual observables (exit outcome, session-document contents) go through
  the doc-introspection seam, sparingly — never as a screen substring.
- Seed files, sessions, and Git state through the `~seed` callback. It runs
  before the Eio loop starts, so fixture setup may use blocking helpers such as
  `Project.git`; interactive test steps must not.

Useful examples are `test_turn.ml` for a held turn and virtual time,
`test_dialogs.ml` for suspension, `test_threads.ml` for unordered concurrent
provider requests, and `test_review.ml` for Git-backed fixtures and launch
state.

## Debugging

- `TUI_HARNESS_TIMINGS=1` prints phase timings (host boot, first frame, settle);
  `TUI_HARNESS_DEBUG=1` traces every settle decision. Both go to stderr, which
  windtrap captures — run the exe directly, or route to a file, to read them.
- A hang is almost always a busy loop, not a deadlock: the mosaic loop fiber
  spins without yielding and starves the script's breath. Confirm with
  `ps -o %cpu` (≈100 %) and locate it with macOS `sample <pid>` — a virtual-time
  spin shows a tower of `read_events` / `compute_timeout` / `handle_every_subs`,
  not the render pipeline.
- A flaky golden is a determinism bug, not something to re-golden. When a frame
  varies run to run, find what advanced the clock outside `advance`: trace every
  `set_time` (its magnitude tells you which timer fired) and check it against
  the four invariants above before touching the harness.
- Never run `--auto-promote` on the shared `test/tui` runtest alias. It can
  promote unrelated failing executables and enshrine a transient frame. Run one
  executable in isolation, inspect its output, then promote only its source
  path with `dune promote test/tui/<file>.ml`.
- Run the one exe directly (not `dune runtest`) for a fast tight loop, and force
  a sweep — `for i in $(seq 1 30); do ./_build/default/test/tui/<exe>; done`
  — before trusting a determinism fix. A harness change re-runs `test_home` and
  `test_turn` plus 30× sweeps of both. A change to release, suspension, or
  unordered serving also sweeps the representative dialog, tool, and thread
  tests that exercise that seam.
