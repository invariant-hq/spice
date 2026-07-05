---
description: Guides writing effective tests for OCaml code — choosing the right test level, using windtrap for unit, property, snapshot, and expect tests, and dune cram tests for executables. Use when writing tests, adding a test suite to a project, reviewing existing tests, or setting up cram tests. Triggers on phrases like "write tests for this", "add a test suite", "test this function", "set up cram tests", "property test this", "snapshot test", "review these tests", or "check coverage".
---

# OCaml Testing

A good test suite tests observable behavior at the cheapest level that
can observe it, fails with output that diagnoses the bug, and stays
deterministic under promotion workflows. Most bad OCaml test suites
fail one of those three.

Before writing any test, survey what exists. Then follow the process
below.

## 1. Survey the Existing Suite

Framework policy: if the repo already has a test suite, follow its
framework and conventions, even where you would choose differently — a
suite split across two frameworks costs more than either framework's
flaws. If there is no suite, use windtrap: one API for unit, property,
snapshot, and expect tests plus coverage beats gluing Alcotest +
QCheck + ppx_expect + Bisect_ppx together.

To survey, grep the `dune` files, not just the `test/` directory:

- `(test` and `(tests` stanzas — standalone test executables.
- `(cram` stanzas and `*.t` files — cram tests.
- `(inline_tests)` — PPX inline tests inside libraries.
- `(libraries ...)` of test stanzas — which framework is in use.

Also note where tests live, how files are named, and whether the suite
runs via `dune runtest` or `dune exec`. Match all of it.

## 2. Choose the Test Level

Blackbox-first: for executables and effectful code, prefer cram tests
through the real binary; reserve unit and property tests for pure
logic. Blackbox tests survive refactors because they pin behavior, not
structure; unit tests of effectful internals tend to over-mock and
calcify the current decomposition.

| Code under test | Level | Why |
|-----------------|-------|-----|
| CLI parsing, exit codes, error messages | Cram | Exercises the real binary; reads as documentation |
| Effectful pipelines (I/O, subprocess, files) | Cram through the binary | Mocking the effects proves little about the wiring |
| Pure function with a law (round-trip, invariant) | Property test | One law covers the input space; shrinking finds minimal bugs |
| Pure function with a few interesting inputs | Unit test or `cases` | Laws don't exist for everything; examples are cheaper |
| Pretty-printer, serializer, formatter | Snapshot or expect | Hand-writing expected structure is noise; promotion keeps it current |
| Internal helper reachable through a public path | Don't test directly | Test through the public surface or the test breaks on refactor |

When code is hard to test — an effectful function with a pure core —
extract the pure core and unit-test that, rather than mocking the
effects around it.

## 3. Write Unit and Property Tests (Windtrap)

Standalone suite:

```lisp
(test
 (name test_mylib)
 (libraries windtrap mylib))
```

Inline tests inside a library:

```lisp
(library
 (name mylib)
 (inline_tests)
 (preprocess (pps ppx_windtrap)))
```

With ppx_windtrap, `let%test "name" = ...` takes a unit-returning body
of windtrap assertions (unlike ppx_inline_test, where the body is a
bool), `module%test Name = struct ... end` groups, and
`let%expect_test` / `[%expect {|...|}]` work as in ppx_expect.

### Unit test style

Assert with testables, not booleans — a testable carries a printer and
equality, so failures show a structured diff instead of "expected
true":

```ocaml
(* Bad: failure output says nothing about the values *)
test "parse" (fun () -> is_true (parse "a,b" = Ok [ "a"; "b" ]))

(* Good: failure shows expected vs actual with a diff *)
test "parses comma-separated fields" (fun () ->
    ok (list string) [ "a"; "b" ] (parse "a,b"))
```

For your own types, expose a printer and build a testable once:

```ocaml
(* In the tested module's .mli *)
val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool

(* In the test *)
let point = testable ~pp:Point.pp ~equal:Point.equal ()
```

Other pieces worth knowing rather than reinventing: `raises` /
`raises_match` / `raises_invalid_arg` for exceptions; `cases` for
table-driven tests (one named test per input, so one bad row doesn't
mask the rest); `bracket ~setup ~teardown` for per-test resources
(teardown runs even on failure); `fixture` for a lazy shared resource;
`skip ~reason ()` for environment-dependent tests.

### Property tests: when they earn their keep

Write a property only when there is a genuine law: a round-trip
(`parse (print x) = Ok x`), an invariant, agreement with a simpler
oracle, or an algebraic identity. A property that re-derives the
answer the same way the implementation does tests nothing — use
example-based `cases` instead.

```ocaml
prop "decode inverts encode" (list string) (fun fields ->
    decode (encode fields) = Ok fields)
```

Generator choice is where properties quietly go wrong:

- Full-range `int` overflows arithmetic laws; use `small_int` (roughly
  ±10k) or `nat` (non-negative, biased small) for sizes, indices, and
  arithmetic.
- `assume` is for rare, cheap preconditions (`assume (b <> 0)`). If
  the precondition is structural, constrain the generator instead —
  heavy discarding exhausts the generation budget and the property
  gives up:

```ocaml
(* Bad: discards almost every case *)
prop "head is min after sort" (list int) (fun l ->
    assume (List.length l >= 2);
    ...)

(* Good: generate valid inputs directly *)
let nonempty_ints =
  Testable.with_gen
    (Gen.list_size (Gen.int_range 1 20) Gen.int)
    (list int)

prop "head is min after sort" nonempty_ints (fun l -> ...)
```

Custom generators use `Gen` combinators (`Gen.oneofl`,
`Gen.frequency`, `Gen.int_range`, `let+`/`and+`, `Gen.fix` for
recursive types) and attach via `testable ~pp ~gen ()` or
`Testable.with_gen`. Shrinking is integrated QCheck2-style: generators
carry shrink trees, so anything built from `Gen` combinators shrinks
automatically — there is no separate shrinker to write.

Two more habits that pay off:

- Reproduce a failure with the reported seed: `--seed N` (or
  `WINDTRAP_SEED`). Fix the bug before touching the generator.
- If a property never fails, check it is exercising the interesting
  region: `classify "empty" (l = [])` reports the input distribution,
  and `cover ~label:"collision" ~at_least:5.0 cond` fails the test if
  the region is under-sampled.

## 4. Write Snapshot and Expect Tests

Both compare program output against stored expectations; they differ
in where the expectation lives.

| | Expect (`expect`, `[%expect]`) | Snapshot (`snapshot`) |
|--|--|--|
| Expectation lives | Inline in the test file | `__snapshots__/<file>/<key>.snap` next to the source |
| Best for | Short output you want visible in code review | Larger generated output (JSON, reports, renders) |
| Update via | `.corrected` files + `dune promote` (inline PPX) | `-u` flag or `WINDTRAP_UPDATE=1` |

Mechanics that differ from naive expectations:

- `expect` normalizes whitespace (strips trailing spaces and
  leading/trailing blank lines, matching ppx_expect); use
  `expect_exact` / `[%expect_exact]` only when whitespace is
  semantically significant.
- Snapshots key on source position by default (`L42_C10.snap`), so
  moving code orphans them; pass `~name:"stable-name"` for anything
  long-lived.
- Nondeterministic fragments (timings, paths, ordering) must be masked
  before comparison, or every run diffs. `output ()` (or
  `[%expect.output]`) consumes captured stdout for post-processing:

```ocaml
test "reports duration" (fun () ->
    run_job ();
    let masked = mask_durations (output ()) in
    (* e.g. "Done in 37ms" -> "Done in XXms" *)
    expect masked)
```

Promotion discipline: promotion is where bugs get blessed as expected
output. Read the diff of every `.corrected` or `-u` update as
carefully as a code change; never batch-promote output you have not
read.

## 5. Write Cram Tests

Cram tests are shell sessions with expected output, run by dune.
Recent dune enables them by default; older projects need
`(cram enable)` in `dune-project`. A test is a `foo.t` file, or a
`foo.t/` directory containing `run.t` plus fixture files the test can
reference — use the directory form whenever the test needs input
files.

Non-obvious mechanics:

- Declare the binary as a dependency, or dune will not rebuild it
  before running the test and you will test stale code:

```lisp
(cram
 (applies_to :whole_subtree)
 (deps %{bin:mytool}))
```

  `%{bin:...}` resolves public executable names (needs a
  `public_name`); for private executables depend on the path
  (`(deps ../bin/main.exe)`).

- Each `.t` file runs as one shell session: `export`s and `cd`s
  persist across commands in the file, so set up env once at the top.

- A command's nonzero exit status appears as a trailing `[1]` line in
  the expected output. Asserting exit codes is half the value of a
  cram test — never let promotion silently absorb an unexpected `[1]`.

- Dune sanitizes only the sandbox path (shown as `$TESTCASE_ROOT`).
  Everything else — timestamps, durations, home paths, version
  strings, hash values — you must sanitize yourself with `sed`, or
  assert on stable fragments with `grep -o` (for JSON, grep for the
  exact key-value fragments you care about rather than matching the
  whole document). Sort any `ls` output; directory order is not
  stable.

- Promotion: `dune runtest` shows the diff, `dune promote` accepts it
  (or `dune runtest --auto-promote`). Same review discipline as
  snapshots.

Prefer a cram test over a unit test when the behavior is "user runs a
command and sees output": argument parsing, error messages, exit
codes, effects on the filesystem. It tests the wiring no unit test
reaches and doubles as documentation of the CLI contract.

## 6. Run, Iterate, and Measure Coverage

Iteration flow for a windtrap suite:

- `dune runtest` runs everything; `dune exec ./test/test_mylib.exe --
  -f pattern` runs a subset; `-x` stops at first failure; `--failed`
  reruns only last run's failures.
- `ftest` / `fgroup` focus a test during development (only focused
  tests run, with a warning); remove them before committing.
- Exit code 2 means no tests ran — usually a filter typo. Treat it as
  a failure, not a pass.

Coverage is built in. Add an instrumentation stanza to the code under
measurement:

```lisp
(library
 (name mylib)
 (instrumentation (backend ppx_windtrap)))
```

Then `dune runtest --instrument-with ppx_windtrap` prints an inline
percentage; `dune exec windtrap -- coverage` gives a per-file report,
`-u` shows uncovered source snippets (the most useful mode for finding
missing tests), and `--json` is machine-readable. Without the flag the
stanza is inert — zero overhead in normal builds. Use coverage to find
untested branches, not to chase a percentage: an uncovered error
branch is a missing test; an uncovered debug helper is fine
(`[@coverage off]`).

## 7. Review Test Quality

Rules that separate useful suites from ceremony, applied to your own
new tests before finishing:

- Don't test the framework, the stdlib, or the type checker: a test
  that `List.sort` sorts, or that a record field holds what the
  constructor assigned, can only fail if OCaml is broken.
- One behavior per test, named by the behavior: `"rejects empty
  input"` diagnoses a failure from the test list alone;
  `"test_parse_2"` forces reading the test body. The name is the first
  line of the failure report — write it for the person debugging.
- Assert the property you care about, not incidental detail. Matching
  full help text to check one flag exists means every unrelated help
  edit breaks the test; grep for the flag.
- If a test needs several fakes to check one line, the test is at the
  wrong level: move up to a cram test of the real binary, or extract
  the pure logic and test that.
- Make failures diagnosable before they happen: testables over
  booleans, `~msg` on assertions inside loops (which iteration
  failed?), `failf` with the offending value in custom checks.
- A test you never saw fail is unverified. When fixing a bug, write
  the failing test first; when writing new tests, sanity-break the
  code once to confirm the test catches it.

## Checklist

- [ ] Existing suite surveyed; framework and conventions matched
      (windtrap only if starting fresh)
- [ ] Test level chosen deliberately: cram for executables/effects,
      unit/property for pure logic
- [ ] Assertions use testables with printers; failures show diffs, not
      "expected true"
- [ ] Properties encode real laws; generators constrained instead of
      leaning on `assume`; sizes use `small_int`/`nat`
- [ ] Snapshot/expect output deterministic: timings, paths, and
      ordering masked before comparison
- [ ] Long-lived snapshots named (`~name`), not position-keyed
- [ ] Cram stanza declares `(deps %{bin:...})`; exit codes asserted;
      unstable output sanitized or grepped for fragments
- [ ] Every promoted diff (`dune promote`, `-u`) read and reviewed as
      a code change
- [ ] No focused tests (`ftest`/`fgroup`) left in; suite exits 0, and
      exit 2 (nothing ran) treated as failure
- [ ] Each new test seen failing at least once; names describe
      behavior; one behavior per test
