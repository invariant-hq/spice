---
description: Guides writing concurrent and parallel OCaml 5 code — choosing between Eio, Lwt, Miou, and Domainslib, using domains correctly, sharing state under the memory model, and structured concurrency with cancellation. Use when adding concurrency or parallelism, writing or reviewing code that uses domains, fibers, promises, Atomic, or Mutex, or when reasoning about races and deadlocks. Triggers on phrases like "make this concurrent", "parallelize this", "use domains", "Eio or Lwt", "data race", "run in parallel", "thread-safe", or "async".
---

# OCaml Concurrency and Parallelism

OCaml 5 separates two ideas that are easy to conflate: **concurrency**
(overlapping I/O waits — fibers or promises inside one domain) and
**parallelism** (using multiple cores — domains). Most code needs one or
the other, not both. Getting this wrong is the most common OCaml 5
mistake: domains are not green threads, and fibers do not use more cores.

Design note first: per `ocaml-library-design`, keep library cores
concurrency-neutral — accept functions or small interfaces, and pick the
runtime at the edge (executables, adapters). Concurrency choices below
are edge decisions.

## 1. Choose the Model

Follow the codebase's existing runtime before any preference below.
Never introduce a second concurrency runtime into a project that has
one — a split runtime forks the ecosystem inside your own repo, and the
community explicitly cannot afford the split either (the library choice
is genuinely contested; assert a decision, not a consensus).

| Situation | Choice | Why |
|-----------|--------|-----|
| Existing Lwt (or js_of_ocaml) codebase | Stay on Lwt | Actively maintained, ~500 dependents; effects do not work from browser event handlers. `lwt_direct` adds direct-style `await` on Lwt if the monad chafes |
| New native concurrent I/O | Eio | Feature-complete direct-style effects library: structured concurrency, io_uring on Linux, real backtraces |
| Minimalist alternative, Mirage orbit | Miou | Actively developed, no capability plumbing, manages domains itself |
| CPU-bound parallelism | Domainslib (or Moonpool) task pool | The manual's own recommendation; work-stealing pools over raw domains |
| Lwt and Eio must coexist | lwt_eio bridge | One event loop, neither side starves; Lwt jobs keep Lwt performance |

Do not hand-roll schedulers on raw `Effect` handlers in application
code (section 6).

## 2. Domains: Few, Pooled, Long-Lived

Domains are heavyweight: each maps 1:1 to an OS thread and carries its
own runtime state. Spawning is expensive and there is a **hard limit of
128 live domains** — domain-per-task does not just perform badly, it
crashes under load.

- Size pools with `Domain.recommended_domain_count ()`; subtract one
  when the calling domain participates in the work:

```ocaml
let pool =
  Task.setup_pool ~num_domains:(Domain.recommended_domain_count () - 1) ()
```

- In Eio, use `Eio.Executor_pool` (the recommended multicore path) or
  `Eio.Domain_manager.run` — not raw `Domain.spawn`.
- Parallelism is a performance change: measure it (`ocaml-perf`,
  `ocaml-benchmarking`). Parallel overhead loses on small workloads.
- `Domain.at_exit` is domain-local: cleanup registered on the main
  domain does not run for workers.

## 3. Shared State and the Memory Model

OCaml gives DRF-SC: a program without data races behaves sequentially
consistently. With races, programs do not crash and values are not
garbage — a racy read returns a possibly **stale** value, and the damage
is bounded to the racy locations. That safety net makes races quieter
and therefore easier to ship; do not mistake "no segfault" for "no bug".

Escalate through this ladder, stopping at the first rung that works:

1. **Immutable data + message passing.** Nothing to synchronize. The
   idiom "write plain data, then publish through an `Atomic`" is
   correct: atomic operations carry synchronization, so the reader that
   sees the flag also sees the data.
2. **`Atomic`** for flags, counters, and lock-free single cells. Since
   OCaml 5.4, record fields can be atomic in place
   (`mutable n : int [@atomic]` with `Atomic.Loc`), without a separate
   `Atomic.t` box.
3. **`Mutex` + `Condition`** for compound mutable structures — a shared
   `Hashtbl` needs a lock around every access, not just writes.

If the design needs more than rung 3 — lock ordering across several
mutexes, ad-hoc lock-free algorithms — reshape the design toward
messages instead; that complexity rarely survives review or refactors.

## 4. The Stdlib Under Concurrency

- `Hashtbl`, `Buffer`, `Queue`, `Stack` are memory-safe but **not
  thread-safe**: concurrent use needs a mutex or a per-domain instance.
  Prefer per-domain instances; locks around hot shared structures
  serialize the parallelism you paid domains for.
- Global stdlib state was made domain-local in 5.x: `Format` printing
  from two domains no longer corrupts state (output can still
  interleave), `Random` gives each domain an independently split
  generator (but systhreads within a domain share it), `Filename` and
  `Hashtbl` seeding are safe.
- `Lazy.force` is not concurrency-safe: concurrent or recursive forcing
  raises `Lazy.Undefined`. Guard shared lazies with a lock or force
  them before going parallel.

## 5. Structured Concurrency (Eio)

- `Switch.run fn` creates a scope: it waits for every fiber attached to
  the switch and releases attached resources when done. Resources
  registered with `Switch.on_release` die with the switch — tie every
  resource to a switch rather than freeing manually.
- `Fiber.fork ~sw` attaches work the switch waits for;
  `Fiber.fork_daemon` is for background services the switch should kill
  on exit instead of waiting for.
- **Cancellation is an exception.** Any operation that can switch
  fibers can raise `Cancelled`; one fiber failing cancels its siblings
  and `Switch.run` re-raises the first real error. Cleanup that must
  complete even during cancellation goes inside `Eio.Cancel.protect`.
- **Blocking blocks the whole domain.** Fibers are cooperative: a raw
  blocking `Unix.*` call or a long pure computation starves every other
  fiber in the domain. Use Eio's own I/O, wrap unavoidable blocking
  calls in `Eio_unix.run_in_systhread`, and push long computations to an
  executor pool.

## 6. Effects: At the Source, Not in the Middle

Effect handlers are the mechanism under Eio, Miou, affect, and
`lwt_direct`; application code should consume those libraries, not
define handlers. Effects are untyped (an unhandled `perform` raises
`Effect.Unhandled` at runtime — the compiler checks nothing) and
continuations are one-shot (resuming twice raises
`Continuation_already_resumed`). Writing a correct scheduler is library
work; using one is application work. OCaml 5.3's `effect` syntax makes
handler code more readable but changes none of this.

When you do design with effects, two rules keep a stack sane:

**Effects for control flow, exceptions for errors.** Suspension —
waiting for data, yielding to the scheduler — is an effect. EOF,
malformed input, and violated invariants are exceptions. A parser that
performs a suspension effect has confused the two.

**Perform effects at the source; keep the middle effect-agnostic.**
The layer that actually waits (an Eio flow, an fd wrapped by a fiber
runtime) performs the effects, and the runtime at the top handles them.
Everything in between stays effect-agnostic by accepting functions: a
streaming layer that calls a caller-supplied pull function transparently
propagates whatever effects that function performs, without depending on
any effect system. Protocol parsers above it stay pure — same parser,
any runtime, trivially testable.

```ocaml
(* Wrong: the parser knows about suspension. *)
let get_byte t =
  if no_data t then perform Await; ...

(* Right: the pull function may suspend (source's business);
   the parser sees data or a true end-of-data and raises on EOF. *)
let get_byte t =
  match pull_next_slice t with   (* may perform effects internally *)
  | Some slice -> ...
  | None -> raise End_of_file    (* final EOF: an error, not a wait *)
```

An end-of-data sentinel (`Slice.eod`-style, see `ocaml-module-design`)
means *no more data will ever come* — the source already did its
waiting via effects before returning it. It is never "try again later".

## 7. Verify Under TSan

Do not reason a race away from the code — reproduce it. ThreadSanitizer
is an official compiler feature (OCaml 5.2+):

```
opam switch create tsan ocaml-option-tsan
dune runtest   # in that switch: all native code is instrumented
```

TSan reports a race whenever two unsynchronized accesses overlap and one
writes. Expect a 2–7x slowdown and higher memory — a CI job, not the dev
loop. Run the existing test suite under it whenever code touching
domains, `Atomic`, or `Mutex` changes. For race and deadlock diagnosis
workflow, load `ocaml-debug`.

## Checklist

- [ ] Existing runtime followed; no second concurrency library
      introduced into the codebase
- [ ] Concurrency vs parallelism identified; fibers for I/O overlap,
      domain pools for CPU work — never domain-per-task (128 hard limit)
- [ ] Pools sized from `Domain.recommended_domain_count`, reusing
      long-lived domains
- [ ] Shared state at the lowest workable rung: immutable/messages,
      then Atomic, then Mutex; no ad-hoc lock-free cleverness
- [ ] No shared mutable stdlib structures (Hashtbl/Buffer/Queue)
      without a lock or per-domain instances; shared lazies guarded
- [ ] Resources tied to switches; cleanup that must survive
      cancellation wrapped in Cancel.protect (Eio)
- [ ] No blocking syscalls or long computations inside fibers without
      run_in_systhread or an executor pool
- [ ] No hand-rolled effect handlers in application code; effects
      performed at the source, middle layers effect-agnostic (accept
      functions), parsers raise exceptions for EOF and errors
- [ ] Parallel speedup measured, not assumed (`ocaml-benchmarking`)
- [ ] Test suite run under a TSan switch when domain-visible state
      changed
