---
description: Guides setting up and maintaining benchmark suites for OCaml code. Use when adding benchmarks, setting up a bench suite, tracking performance regressions, wiring benchmarks into dune runtest, or proving that an optimization holds. Triggers on phrases like "add a benchmark", "set up benchmarks", "bench suite", "performance regression", "thumper", "baseline", or "did this get slower". For diagnosing and fixing slowness, load ocaml-perf.
---

# OCaml Benchmarking

This skill covers the harness: building benchmark suites that prove
changes and prevent regressions. Finding hotspots and optimizing them
is the `ocaml-perf` skill; use it to decide *what* to benchmark, use
this skill to make those measurements repeatable and enforced.

## 1. Survey Existing Benchmarks

Before adding anything, look for an existing suite (`bench/`,
`benchmarks/`, `dune` files depending on `thumper`, `bechamel`, or
`core_bench`, committed `.thumper` files). If one exists, follow its
framework and conventions --- a project with two benchmarking styles
has two sets of numbers nobody can compare.

If there is no suite, use [thumper](https://github.com/invariant-hq/thumper).
Reason: thumper makes benchmarks regression tests wired into
`dune runtest` --- regressions fail the build, improvements ratchet
the baseline via `dune promote` --- whereas standalone bench scripts
are run once, drift, and rot.

## 2. Choose Targets

Benchmark hot paths, not everything. A suite that measures fifty
incidental functions is slow to run, noisy to review, and buries the
regression that matters. Good targets:

- Functions that profiling (see `ocaml-perf`) identified as hot.
- Code with a performance contract (parsers, encoders, core loops).
- Code you just optimized --- the benchmark is the proof and the guard.

For each target, pick representative inputs and realistic sizes. A
parser benchmarked on a 12-byte string tells you nothing about the
1 MB documents it sees in production. Parameterize over sizes when
the scaling behavior is the interesting part
(`Thumper.bench_param "parse" ~params:[("1k", d1k); ("1M", d1m)] ~f:parse`).

## 3. Set Up the Harness

### Suite structure

One executable per suite, one suite per subject area. The suite name
passed to `Thumper.run` names the baseline file (`<name>.thumper`).

```ocaml
let () =
  Thumper.run "parser"
    [
      Thumper.bench "json small" (fun () -> parse json_small);
      Thumper.group "large inputs"
        [
          Thumper.bench "json 1M" (fun () -> parse json_1m);
          Thumper.bench "xml 1M" (fun () -> parse_xml xml_1m);
        ];
    ]
```

Benchmark names become stable ids used for baseline matching (pass
`?id` explicitly if you expect to rename). Renaming a benchmark
without an id orphans its baseline entry, so treat names as API.

### Keep setup out of the measured region

`Thumper.bench f` times everything inside `f`. Building the input
inside `f` measures the constructor, not the subject:

```ocaml
(* Bad: allocation of the input dominates the measurement *)
Thumper.bench "sort" (fun () -> List.sort compare (List.init 10_000 Fun.id))

(* Good: setup runs outside the measured region *)
Thumper.bench_with_setup
  ~setup:(fun () -> List.init 10_000 Fun.id)
  "sort" (fun xs -> List.sort compare xs)
```

Use `bench_staged ~init ~setup` when the input is consumed or mutated
per call (e.g. sorting in place): `init`/`fini` run once per worker,
`setup`/`teardown` run per measured batch, and only the function
itself is timed.

### Dune integration

```dune
(executable
 (name bench_parser)
 (libraries thumper mylib))

(rule
 (alias runtest)
 (action
  (progn
   (run %{exe:bench_parser.exe} -q)
   (diff? parser.thumper parser.thumper.corrected))))
```

The pieces matter individually: `-q` gives one character per case so
dune output stays readable; `diff?` is what turns an improvement's
`.corrected` file into a promotable diff and does nothing when the
run is equivalent (no noise). A regression exits nonzero and fails
the rule directly --- no `.corrected` is written, so a failing run
can never be `dune promote`d away.

## 4. Establish the Baseline

The baseline lifecycle, in order:

1. `dune runtest` --- first run finds no baseline, creates
   `<name>.thumper` in the build directory, and prints the `cp`
   command to copy it into the source tree.
2. Copy it and `git add` it. The committed file is the contract;
   an uncommitted baseline protects nobody.
3. Subsequent `dune runtest` runs compare against it. Equivalent
   results produce no diff; improvements produce a diff that
   `dune promote` ratchets into the baseline; regressions fail.
4. After an *intentional* slowdown (new feature, correctness fix),
   re-bless: `dune exec bench/bench_parser.exe -- --bless`, then
   `dune promote`. Say why in the commit message --- a blessed
   regression without rationale looks identical to a hidden one.

For interactive work, `--explore` measures and prints with no
baseline interaction, and `--quick` trades precision for a 2 s
budget --- use these while iterating, not for the committed verdict.

Verdicts are confidence-interval based, not point comparisons: a case
is `Improved` only when its CI clears the equivalence band (default
5%), so ordinary run-to-run jitter cannot ratchet the baseline. Tune
the contract per suite or per case with budgets:

```ocaml
Thumper.run "parser"
  ~budgets:
    [
      Thumper.Budget.no_slower_than 0.10;
      Thumper.Budget.no_more_alloc_than 0.02;
    ]
  [ (* ... *) ]
```

`no_more_alloc_than` deserves a much tighter bound than time:
allocation counts barely vary between runs, so they gate reliably
where timing would flake.

## 5. Micro-Benchmarking Traps

Thumper handles several of these (noted where); know them anyway,
because you will meet hand-rolled harnesses and other frameworks.

- **Dead-code elimination.** The optimizer deletes computations whose
  results are unused, and you end up benchmarking a no-op.
  `Sys.opaque_identity` is the barrier. Thumper already wraps each
  call's *result*, but constant *inputs* can still be folded away ---
  wrap them in `Thumper.black_box`:

  ```ocaml
  (* Bad: with flambda, [fib 20] can be computed at compile time *)
  Thumper.bench "fib 20" (fun () -> fib 20)

  (* Good: input is opaque, the call must happen at run time *)
  let n = Thumper.black_box 20 in
  Thumper.bench "fib 20" (fun () -> fib n)
  ```

- **GC state bleeding between cases.** A benchmark that inherits a
  full minor heap from its predecessor pays for the predecessor's
  garbage. Thumper's config has a `gc` policy (major collection
  between samples by default; compaction in the `ci` preset) and a
  `fork` policy (`ci` forks per case for full isolation). In a
  hand-rolled loop, `Gc.major ()` between cases is the minimum.

- **Missing warm-up.** First iterations pay for cache fills, lazy
  initialization, and branch-predictor training; including them skews
  small benchmarks. Thumper calibrates and warms up before sampling.
  If you write a raw loop, discard the first runs.

- **Time vs. allocations.** Wall/CPU time answers "how fast"; words
  allocated answers "how much GC pressure" and is exactly reproducible
  run to run. When timing is too noisy to gate on, gate on allocations
  (`Metric.alloc_words` is measured by default; the `--deterministic`
  preset makes allocation the primary metric).

- **Bytecode by accident.** Bytecode is several times slower and
  allocates differently; a baseline measured in one and checked in
  the other fails everywhere. `%{exe:...}` in the dune rule picks the
  native executable when the platform has it --- keep it that way, and
  benchmark under the compiler settings you ship (a dev-profile
  flambda-off measurement says little about a release binary).

- **Noisy environments and committed baselines.** A baseline encodes
  the machine that produced it; shared CI runners and laptops on
  battery produce different numbers. Options, in order of preference:
  gate on allocation budgets (machine-independent), widen time budgets
  for CI, or keep per-environment baselines using
  `--profile`/`Config.profile` (the profile and host fingerprint are
  recorded in the baseline). Thumper auto-selects its low-noise `ci`
  preset (longer runs, tighter CI, fork per case) when `CI` or
  `GITHUB_ACTIONS` is set.

## 6. Maintain the Suite

- Run benchmarks through `dune runtest` like any other test; a bench
  suite outside the default test flow is a bench suite nobody runs.
- Keep suites fast enough to tolerate. The `default` preset spends up
  to 10 s per case; a 40-case suite is a seven-minute test run. Split
  suites, prune cases that no longer guard anything, or tighten
  `Config.max_time`.
- When a regression fires, treat it like a failing test: reproduce
  locally (`dune exec ... -- -f <name>` filters to one case), then
  switch to the `ocaml-perf` skill to diagnose and fix. Only re-bless
  when the slowdown is a decision, not a mystery.
- Review baseline diffs in PRs the way you review golden test diffs.
  An unexplained `.thumper` change in an unrelated PR is a smell.
- When benchmarks are added or renamed, regenerate the baseline in the
  same commit so `main` never has orphaned or missing entries.

## Checklist

- [ ] Existing bench framework followed, or thumper chosen for a
      fresh suite
- [ ] Targets are profiled hot paths or contract-bearing code, with
      representative inputs --- not blanket coverage
- [ ] Setup and teardown run outside the measured region
      (`bench_with_setup` / `bench_staged`)
- [ ] Constant inputs wrapped in `black_box` so nothing is
      compile-time folded
- [ ] Dune rule wires the suite into `runtest` with `-q` and `diff?`
      on the `.thumper` file
- [ ] Baseline committed; first-run `cp` step not forgotten
- [ ] Budgets set deliberately: tight (or zero) on allocations,
      realistic on time for the environment that runs the checks
- [ ] Native code measured, under release-like compiler settings
- [ ] CI noise strategy chosen: allocation gates, widened budgets, or
      per-profile baselines
- [ ] Intentional regressions re-blessed with rationale in the commit
