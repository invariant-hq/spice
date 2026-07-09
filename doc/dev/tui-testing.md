# Deterministic TUI tests

Developer reference for the in-process TUI test suite at `test/tui-next`. It
drives the real application — `App.init/update/view/subscriptions`, the real
runtime command interpreter, the real host and session store, the real provider
wire protocol — through the same event vocabulary a terminal produces, and
observes only the rendered cell grid. No pty, no subprocess, no wall clock. The
design rationale (why a third suite, the v2 autopsy) lives in the plan; this doc
is the operational contract: how the harness stays deterministic and what breaks
it. The harness itself is `test/tui-next/harness/`; `test_home.ml` and
`test_turn.ml` are the canonical idioms.

## The model

The app runs under `Spice_tui.run` with its environment swapped through public
seams: a headless `Matrix_test` backend (mosaic's `matrix.test`), one virtual
clock, a pinned process-environment snapshot, and the Mosaic runtime probe. The
mosaic loop runs in one Eio fiber and parks in the backend's `on_idle`; the test
script runs in another. A test:

- **drives** with `Tui.keys` / `Tui.enter` / `Tui.paste` / `Tui.resize` (raw
  bytes through the real input parser, so decode regressions stay covered);
- **waits** with `Tui.settle` (quiescence) or `Tui.advance dt` (virtual time) —
  never a sleep, never a substring-with-deadline;
- **gates** the provider with `Tui.await_request` / `Tui.release` (a held reply
  is a named `Eio.Promise`, so a mid-flight state is observable for exactly as
  long as the test needs);
- **asserts** a full 24-row frame via `Tui.print` at a pinned size (default
  80×24). Substring facts are forbidden; a frame is a `[%expect]` golden,
  promoted with scoped `dune promote test/tui-next/<file>`.

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

## Settle and advance

- `settle` blocks until the backend is parked, the probe reports no pending
  messages / in-flight performs / unsettled renderer, no redraw is queued, and a
  short scheduler drain turns up nothing new. A perform parked on a **held**
  provider gate counts as settled — that held mid-flight state is exactly what a
  test observes. It carries a loud budget; it never hangs.
- `advance dt` steps virtual time forward by `dt` in cadence-sized steps, firing
  due `Sub.every` / `Sub.on_tick` timers, then settles without quantizing.
  Elapsed counters tick exactly `dt`; ages age exactly `dt`.
- `await_request n` pumps (settle + a 1 ms real breath) until the n-th request
  reaches the in-process provider, then returns its body. It fails loudly rather
  than hanging.

The only real-clock sleep in the harness is a 1 ms scheduler breath while real
IO (localhost HTTP, tool subprocesses, fswatch systhreads) is genuinely in
flight; park-waiting is condition-based, not polled.

## Writing a test

- **Full frames, pinned size.** `Tui.print` prints the whole 80×24 grid,
  normalized (`$PROJECT`, `ses_$ID`). Assert the frame, not a line.
- **Batch scenarios that share state into one `Tui.run`** — a boot is ~60 ms.
  `test_turn` prints three frames (working, ticked, settled) from one boot.
  Don't contort unrelated scenarios together.
- **Send Enter as its own write** (`Tui.enter`), never `"/cmd\r"` in one chunk.
- **Reduced motion and workspace tooling are off by default**; opt in per test
  with `~env` only when the animation or the dune footer is the behaviour under
  test (workspace tooling on spawns a real `dune`, ~1.5 s and a footer race).
- Non-visual observables (exit outcome, session-document contents) go through
  the doc-introspection seam, sparingly — never as a screen substring.

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
- Run the one exe directly (not `dune runtest`) for a fast tight loop, and force
  a sweep — `for i in $(seq 1 30); do ./_build/default/test/tui-next/<exe>; done`
  — before trusting a determinism fix. A harness change re-runs `test_home` and
  `test_turn` plus 30× sweeps of both.
