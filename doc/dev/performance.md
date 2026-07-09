# Performance notes: TUI launch and the test suite

Developer reference. User-facing behavior lives in the manual
(`doc/manual/configuration.md`, "Workspace tooling"); the deterministic TUI
harness these notes lean on lives in `test/tui-next/harness/`. Numbers are
from 2026-07-09 on an M-class laptop — treat them as budgets, not gospel.

## The launch budget

The TUI's first frame must never wait on network, TLS, subprocesses, or
directory scans. The launch path is budgeted:

| Phase | Cost | What it is |
| --- | --- | --- |
| Host boot | ~2 ms | Config layers, host load, session store, snapshot. |
| Loop bring-up | ~7 ms | Mosaic renderer/reconciler, first frame render. |
| Launch background | tens of ms, off-path | Brief load, prewarm, tooling. |

Two classes of regression have already been caught and are worth guarding
against by name:

- **Eager crypto/TLS init.** `Mirage_crypto_rng_unix.use_default` (~30 ms,
  entropy seeding) and `Ca_certs.authenticator ()` (~35 ms, parses the whole
  system CA bundle) used to run *eagerly at client construction* — three
  times, unshared — because `build_run` evaluated the HTTP clients as
  arguments on the prewarm path. They now live behind one shared `lazy` in
  `Spice_host_builtin`, forced on the first TLS handshake. Keep it that way:
  constructing a client must not initialize TLS.
- **Synchronous subprocess spawns.** `discover_repo` (a `git rev-parse`
  spawn, ~18 ms) ran at brief-loader *construction*; it is now lazy, paid by
  the first asynchronous brief load. The workspace Dune tooling
  (`dune describe`, `dune build --watch`, fswatch, Merlin) is gated by
  `workspace.tooling` and engages only in Dune workspaces — and never on the
  first-frame path.

The rule behind both: **construction is free; first use pays.** Anything
observable in the first frame must come from data already on the boot path;
everything else is lazy or delivered asynchronously after the frame renders.

## Measuring

The deterministic TUI harness doubles as the launch profiler:

```
TUI_HARNESS_TIMINGS=1 ./_build/default/test/tui-next/test_home.exe -f "boots" 2>&1 | grep 't+'
```

- `run: launching` → `loop: probe received` — the host boot span.
- `probe received` → `loop: first park` — Mosaic bring-up and first frame.
- `first park` → `settle: end` — launch background work the settle waits out
  (brief load; the tooling when engaged).

`TUI_HARNESS_DEBUG=1` traces every settle decision (pending performs,
messages, render work, cadence-gated frames) when a settle misbehaves.

For the real binary, `time spice --help` measures process overhead (dominated
by first-exec page-in of the ~44 MB binary); the TUI-specific path is best
watched through the harness, which runs the identical code.

## The test-suite cost model

A `Tui.run` boot in `test/tui-next` costs ~60 ms wall: ~2 ms host boot,
~10 ms to the first frame, the rest launch-background settle and teardown. A
full turn against the in-process provider is ~215 ms with workspace tooling
off (the harness default; with tooling engaged the real `dune` spawns add
~1.5 s and a nondeterministic footer race — only tests that assert tooling
behavior should turn it on).

Consequences for test authoring:

- **Batch scenarios that share state into one boot** — the turn pilot prints
  three frames from one boot. Don't contort unrelated scenarios together.
- **Time is free.** `Tui.advance` marches virtual time with one real render
  per 100 ms of virtual time (the harness cadence is 10 fps; the app's finest
  timer is 0.1 s, so timer fidelity is exact). Never trade determinism for
  speed by skipping settles.
- **The harness never sleeps on your behalf** beyond 1 ms scheduler pumps
  while real IO is genuinely in flight; if a test feels slow, profile it with
  the timing env vars before touching the harness.
