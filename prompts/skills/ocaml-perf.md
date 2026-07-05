---
description: Guides measurement-driven performance optimization of OCaml code. Use when optimizing, profiling, speeding up, or reducing allocations in OCaml code, and when reviewing performance-sensitive code. Triggers on phrases like "make this faster", "too many allocations", "profile this", "optimize", "GC pressure", "hot loop", or "why is this slow". For setting up a benchmark suite, load ocaml-benchmarking.
---

# OCaml Performance Engineering

Performance work starts from measurement, not intuition. Never
optimize code you have not profiled. Never assume a change helped
without re-measuring.

Read the code the user points to. Before changing anything, understand
what is slow and why. Then follow the process below.

## 1. Establish a Baseline

This is the most important step. Without a baseline, you cannot know
whether a change helped or hurt.

### Define the workload and success metric

Before touching code, answer:

- What is the workload? (a function, a benchmark, a request path)
- What is the metric? (wall time, throughput, allocation rate, latency)
- What is the target? (2x faster, halve allocations, fit in cache)

If there is no benchmark, build one — load `ocaml-benchmarking` for
harness setup. A measurement you can repeat is worth more than any
optimization you cannot verify.

### Capture GC counters

Wrap the workload with `Gc.quick_stat` before and after. Record:

- `minor_words`: total words allocated in the minor heap.
- `promoted_words`: words copied from minor to major (often more
  diagnostic than `minor_words` alone).
- `major_words`: words allocated directly in the major heap.
- `minor_collections`, `major_collections`: GC frequency.

```ocaml
let before = Gc.quick_stat () in
(* ... workload ... *)
let after = Gc.quick_stat () in
Printf.printf "minor: %.0f  promoted: %.0f  major: %.0f\n"
  (after.minor_words -. before.minor_words)
  (after.promoted_words -. before.promoted_words)
  (after.major_words -. before.major_words)
```

These numbers tell you whether you are in an allocation-heavy regime
before you reach for a profiler.

### Capture wall time

Use `Sys.time` or `Unix.gettimeofday` for coarse timing. For
micro-benchmarks, use a proper harness (see `ocaml-benchmarking`) or a
simple loop with `Sys.opaque_identity` to prevent dead-code
elimination:

```ocaml
let result = Sys.opaque_identity (f input) in
ignore result
```

`Sys.opaque_identity` is the correct anti-optimization barrier. Do
not use ad-hoc hacks (`Printf.printf "%d"`, writing to `/dev/null`).

### Measure the right build

Benchmark with `dune build --profile release`. The default dev profile
passes `-opaque` (which blocks cross-module inlining) and enables no
optimization; numbers from a dev build routinely mislead. Pin compiler
version, flags, and `OCAMLRUNPARAM` for reproducibility, separate
warmup from measurement, and report distributions (median, variance),
not single times.

## 2. Diagnose the Bottleneck

OCaml performance is dominated by three forces: **allocation rate**,
**cache behavior**, and **optimizer effectiveness**. Identify which
one you are fighting before choosing a fix.

### Separate CPU time from allocation cost

High `minor_words` with frequent `minor_collections` points to
allocation pressure. High wall time with low allocation points to
CPU-bound work (numeric loops, syscalls, cache misses).

Correlate GC counters with time measurements to classify the
bottleneck.

### Choose the right tool for the question

| Question | Tool | Notes |
|----------|------|-------|
| Where is CPU time going? (Linux) | `perf` sampling profiler | Build with frame pointers (`ocaml-option-fp`) for call graphs — DWARF unwinding breaks on OCaml 5 effect stacks. `perf record -F 99 --call-graph fp` |
| Where is CPU time going? (macOS) | Instruments or `samply` | Sampling; frame pointers help as with `perf` (x86_64 needs OCaml 5.3+, ARM64 5.4+) |
| Where are we allocating? | `Gc.Memprof` / memtrace | Statistical sampling. `Gc.Memprof` exists in 4.11–4.14 and 5.3+, but not 5.0–5.2; released memtrace does not yet support OCaml 5 (pin its statmemprof branch) |
| What are the GC pauses? | `Runtime_events` + `olly` | Low-overhead tracing in OCaml 5; `olly trace`/`olly gc-stats` show GC phases per domain |
| Did the compiler inline? | `ocamlopt -S` | Assembly ground truth for inner loops |
| Why wasn't this inlined? | `-inlining-report` (Flambda) | Shows optimizer decisions per round |

Start coarse (GC counters), then narrow (profiler), then inspect
(assembly). Do not jump to assembly inspection without first knowing
where to look.

### Form a hypothesis

Common hypotheses, in rough order of frequency:

1. **Per-iteration allocation**: closures in loops, repeated string
   building, `List.rev`/`@` patterns, `Format`/`Printf` on the hot
   path.
2. **Polymorphic overhead**: `compare`, `(=)`, generic array ops
   where typed alternatives exist.
3. **Poor locality**: pointer-chasing through lists/trees when arrays
   would be contiguous.
4. **Missed inlining**: abstractions that are zero-cost only if the
   compiler sees through them (especially cross-module with `-opaque`
   or without Flambda).
5. **Write barrier cost**: mutating major-heap records to point to
   minor-heap values.

## 3. Apply Targeted Changes

Make one change at a time. Re-measure after each change. If a change
does not measurably help, revert it — complexity without payoff is
pure cost.

### Reduce allocation on the hot path

This is the single most common and most effective optimization in
OCaml. The minor heap is fast (pointer bumping), but high allocation
rates still cost: frequent minor collections, promotion pressure, and
degraded locality.

- **No closures in inner loops** — a `List.iter (fun ...)` in a hot
  loop allocates per call site; a `for` loop over an array does not.
- **Reuse buffers instead of repeated string building.** Allocate
  `Bytes.create` once, refill it, and only `Bytes.to_string` at the
  boundary (I/O or API). This localizes allocation to the boundary,
  not the inner loop.
- **Prefer arrays/Bytes/Bigarray for hot linear data.** Each list cons
  cell is a heap block and traversal is pointer-chasing; arrays give
  contiguous memory and better cache behavior.
- **Avoid accidental allocation traps**: repeated `List.rev` /
  `List.append` in accumulator loops; `Format`/`Printf` on the hot
  path (formatter state, buffering); `String.sub` when an index range
  suffices; tuple allocation for multi-return when a mutable record
  would do.

### Use typed operations instead of polymorphic ones

Polymorphic `compare` and `(=)` involve runtime dispatch and
structural traversal. In hot loops, use `Int.equal`, `String.equal`,
and friends; for collections, instantiate `Map.Make`, `Set.Make`,
`Hashtbl.Make` with explicit comparison/hash functions rather than
polymorphic defaults.

### Improve data locality

OCaml programs are often pointer-rich (lists, trees, closures), which
makes CPU caches the real bottleneck. When profiling shows cache
misses or when data is large and accessed sequentially:

- Replace lists with arrays for sequential access patterns.
- Use `Bigarray` for large numeric buffers (off-heap, contiguous,
  reduces GC pressure).
- Pack related data into fewer heap blocks (records instead of
  separate refs; flat arrays instead of arrays of records).

### Help the optimizer

Many OCaml abstractions are zero-cost only if the compiler can see
through them. When the hot path crosses module boundaries:

- **`-opaque` blocks cross-module inlining.** Dune passes it in the
  dev profile; benchmark and ship with `--profile release`. If a hot
  wrapper still fails to inline cross-module, define it locally in
  the consuming module.

- **Flambda `-O3`** raises inlining/specialization budgets. Use
  `-inlining-report` to verify decisions rather than guessing.
  (Upstream OCaml ships classic Flambda; Flambda 2, unboxed types,
  and modes live in the OxCaml fork — relevant if the user asks about
  those features.)

- **Inlining attributes** (`[@@inline]`, `[@inlined]`,
  `[@@specialise]`, `[@specialised]`, `[@unrolled]`) are tools for
  when the optimizer's heuristic differs from your knowledge of
  hot/cold paths. Use them surgically, not as decoration.

- **Inspect assembly** (`ocamlopt -S`) to confirm the inner loop is
  what you expect: no unexpected allocations, no indirect calls on
  the hot path, bounds checks eliminated where invariants guarantee
  safety.

### Understand the write barrier trade-off

Mutating a major-heap block to point to a minor-heap value triggers
the write barrier (updates the remembered set). In some patterns,
"mutate in place" is slower than "allocate a fresh record".

Guideline: in hot code, pick the representation that minimizes
survivors and major-heap mutations. In cold code, prefer
immutability — GC costs there usually do not matter.

### Use `-unsafe` only with strong invariants

`-unsafe` removes bounds checks on array/string access. It is
appropriate only when invariants are proven and tests are excellent.
Never use it as a first resort.

### Tail recursion and TMC

Make traversals tail-recursive to avoid stack overflow. But know the
nuance: the accumulator+reverse transformation of `List.map` can be
slower and more complex than the direct definition. Tail Modulo
Constructor (TMC) is a compiler transformation that keeps the direct
style stack-safe with competitive performance.

Decision rule:
- Need stack safety, can tolerate overhead: accumulator+reverse.
- Want direct style with stack safety: consider TMC, and measure.

### Float representation

OCaml uses a special unboxed representation for arrays of floats
(historically `Double_array_tag`). There is also an explicit
`floatarray` type. For numeric kernels, confirm the representation
is what you expect using profiling or `-S` inspection rather than
assumptions.

Use `Bigarray` when you need large numeric buffers, C interop, or
reduced GC pressure from huge heap-allocated arrays. Beware that
bigarrays are custom values with out-of-heap memory accounting;
GC pacing involves `custom_*` ratios.

## 4. Validate the Change

- **Re-run benchmarks statistically.** Multiple runs, report variance.
  A single faster run proves nothing.
- **Check GC impact.** Compare `promoted_words`, `major_collections`,
  and pause structure before and after. A change that reduces wall
  time but increases promotion may be fragile.
- **Guard regressions.** Turn the benchmark into a regression test
  that runs in `dune runtest` — load `ocaml-benchmarking`.
  Performance work that is not continuously validated will regress.
- **Document intent.** Explain *why* code is written in an unusual
  way. Performance optimizations are maintenance liabilities; the
  rationale must survive the author.

## 5. GC Tuning (Last Mile)

Treat GC tuning as a last-mile optimization. Fix high allocation
rates first; GC tuning is most effective after you have stabilized
allocation behavior.

### Knobs you can rely on (OCaml 5)

- **`s` (minor heap size)**: controls how often minor collections
  happen. Too small increases GC frequency; too large increases
  latency and memory footprint.
- **`o` (`space_overhead`, default 120)**: the main major-GC pacing
  lever — higher trades memory for less GC work.
- **`v` (verbose GC)**: diagnostic messages for GC phases.
- **`custom_minor_ratio`, `custom_major_ratio`,
  `custom_minor_max_size`**: affect GC pacing for out-of-heap memory
  held by custom blocks (bigarrays).

Set via `Gc.set` programmatically or `OCAMLRUNPARAM` externally.

### OCaml 5 differences

- `major_heap_increment`, `max_overhead`, `allocation_policy`, and
  `window_size` are ignored in OCaml 5 (`space_overhead` still
  works). Expect fewer manual levers and a greater need for
  algorithm/data-structure-level adjustment.
- Compaction returned in OCaml 5.2, but only on demand via
  `Gc.compact` — there is no automatic compaction. For long-running
  processes with heap fragmentation, schedule explicit compactions at
  quiet points.

### Multicore considerations

With OCaml 5 domains:

- Each domain has its own minor heap; no synchronization on
  allocation.
- Minor collections are stop-the-world across all domains.
- The major collector is concurrent with short stop-the-world pauses.
- Immutable values are easy to share; mutable data must be
  synchronized (DRF-SC memory model).
- Measure GC and runtime events at the domain level.

## Checklist

- [ ] Baseline established: workload defined, GC counters and timing
      captured, benchmark repeatable, built with `--profile release`
- [ ] Bottleneck diagnosed: allocation vs CPU vs cache vs optimizer;
      hypothesis formed from profiling, not intuition
- [ ] Changes are targeted: one change at a time, re-measured after
      each; reverted if no measurable improvement
- [ ] Allocation hot spots addressed: no accidental closures, string
      churn, or list-building in inner loops
- [ ] Polymorphic operations replaced with typed alternatives on hot
      paths
- [ ] Compiler output inspected where needed (`-S`, inlining reports)
- [ ] Benchmarks are robust: `Sys.opaque_identity` used correctly,
      warmup separated, variance reported
- [ ] GC tuning applied only after allocation behavior is stable
- [ ] Performance-critical code is documented with rationale
- [ ] Regression guard added (`ocaml-benchmarking`) so `dune runtest`
      catches slowdowns
