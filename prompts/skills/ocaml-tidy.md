---
description: Tidies OCaml .ml implementation code for clarity, density, locality, and maintainability without changing behavior. Use when tidying, cleaning up, simplifying, or readability-refactoring OCaml implementation files or snippets while preserving semantics, and when reviewing .ml code for clarity. Triggers on phrases like "tidy this", "clean up this file", "simplify this code", "refactor for readability", "make this more idiomatic", or "review this .ml".
---

# OCaml Tidy

Tidying is disciplined implementation editing. Make the code simpler, clearer,
more direct, and easier to maintain while preserving the exact same program.

The guiding question:

> Will this edit make the implementation obviously correct, minimal, direct,
> readable, and faithful to the original behavior?

Prefer deleting code, simplifying control flow, improving names, and finding
the right local structure over adding helpers, modules, types, or abstractions.
Every changed line must earn its place.

This skill is for `.ml` implementation code. It is not an API redesign guide
(load `ocaml-module-design` for interface questions) or an optimization guide
(load `ocaml-perf`).

## 0. Non-negotiable rule: preserve behavior

A tidy pass must not change observable behavior unless the user explicitly
asks.

Preserve:

- evaluation order;
- top-level initialization order;
- side effects and mutation order;
- exception constructors, timing, backtraces when relevant, and error messages;
- `raise_notrace`, `Exit`, and other flow-control exception patterns;
- lazy vs strict behavior;
- allocation behavior in hot paths;
- I/O, logging, tracing, metrics, and diagnostics;
- parser, renderer, terminal/UI, array, bytes, bigarray, and buffer behavior;
- public names, types, and module shape exposed through `.mli`.

If behavior is unclear, keep it and tidy around it.

Do not introduce dependencies, PPX, build changes, new public API, or broad
project-wide normalization during a tidy pass.

## 1. Read before editing

Before changing code:

1. Read the whole `.ml` file, not just the target function.
2. Read the nearby `.mli` if it exists.
3. Identify which definitions are public, private, local, or only test-facing.
4. Mark effect boundaries: I/O, logging, mutation, exceptions, callbacks,
   lazy values, global state, resource cleanup.
5. Mark likely hot paths: loops, parsers, renderers, terminal/UI refresh,
   arrays, bytes, strings, bigarrays, buffers, hash tables, queues, stacks.
6. Note local style: naming, formatting, helper placement, error style,
   exception/result conventions.
7. Decide the smallest local edit that removes friction.

For non-trivial tidying, compare real alternatives before editing:

- local helper vs top-level helper;
- direct match vs `Option`/`Result` combinators;
- direct recursion vs `List.fold_*`;
- loop/ref/buffer vs list allocation;
- inline invariant check vs new type/module;
- preserving file order vs moving definitions.

Choose the option that best preserves behavior while making the code simpler
and more obvious.

## 2. What counts as a tidy edit

Good tidy edits usually do one of these:

- delete dead or redundant code;
- remove accidental duplication;
- make control flow flatter or more explicit;
- name a real subproblem or invariant;
- keep related code closer together;
- preserve a hot loop while making its safety clearer;
- replace unclear cleverness with direct OCaml;
- improve a misleading name;
- isolate an effect boundary without hiding it.

Do not rewrite code merely because another style is also valid. If local
conventions already work, leave them alone.

Avoid cosmetic churn:

- do not reorder a file just to fit a preferred narrative;
- do not rename locals unless the new name improves understanding;
- do not convert matches to combinators or pipelines just for compactness;
- do not split functions to satisfy a line-count target;
- do not introduce aliases, records, variants, modules, or functors unless
  they solve a real local problem.

## 3. File shape and locality

Keep definitions close to use.

Local helpers should usually remain local, especially recursive helpers that
serve one function. A top-level helper must earn its place by being reused,
naming a real file-level concept, or isolating a meaningful invariant/effect
boundary.

Do not move top-level definitions casually. In OCaml, top-level bindings are
evaluated in order, and moving them can change effects, initialization,
exceptions, or registration behavior.

A readable implementation file often has this rough shape: constants and small
utilities; types and minimal accessors; core logic; I/O edges and integration
code. Treat that as a narrative aid, not a rule for narrow tidy passes.

Use section comments only when they improve navigation in a real file; avoid
adding section headers to small files.

## 4. Function shape

A tidy function reads top-to-bottom. It has clear inputs, direct control flow,
and bindings close to their use.

Prefer:

* one coherent concern per function;
* simple `let` bindings that explain the computation;
* explicit matches for meaningful branches;
* local recursion for one-off traversals;
* short scopes for short names;
* intentional shadowing after refinement.

Do not split a function just because it is long. Split only when the helper
has a coherent name and improves the reader's model.

Good helpers name a real subproblem, hide a tricky invariant, isolate an
effect boundary, remove real duplication, or make the main function read
naturally. Bad helpers merely forward arguments, save one line, hide important
control flow, force jumping around the file, or add abstraction without
reducing complexity.

Local recursion is often best:

```ocaml
let collect p xs =
  let rec loop acc = function
  | [] -> List.rev acc
  | x :: xs ->
      if p x then loop (x :: acc) xs else loop acc xs
  in
  loop [] xs
```

Use `loop`, `aux`, `scan`, `walk`, or another traversal-shaped name when the
scope is small. Use a domain name when the helper encodes domain meaning.

## 5. Naming

Preserve the surrounding codebase's naming style unless it is actively
harmful.

Use names that make the code read naturally:

* short local names are fine in tiny scopes: `i`, `j`, `n`, `s`, `v`, `acc`,
  `ppf`;
* longer names should encode domain meaning, not implementation anxiety;
* avoid vague names like `data`, `info`, `res`, `tmp` outside tiny scopes;
* avoid over-specific names that describe mechanics rather than meaning.

Rename only when the old name misleads or obscures intent.

Error strings may be named when reused or when the name clarifies the failure
(`let err_empty_name = "empty name"`). Do not extract every string literal
into `err_*`. Do not change observable error messages during tidying.

Alias long paths only when it improves readability in context
(`let strf = Printf.sprintf`). Avoid pointless aliases like `module L = List`.

## 6. Pattern matching and control flow

Prefer clear matches over clever encodings.

Use exhaustive matches when possible. Use `_` only when the remaining cases
are truly uninteresting and future extensions should intentionally take the
same path.

Use `if` for booleans and simple predicates. Use `match` for variants,
options, results, and branch structure that benefits from names.

Tuple matches are good when both values are already available or both must be
evaluated anyway:

```ocaml
match left, right with
| None, _ -> ...
| Some l, None -> ...
| Some l, Some r -> ...
```

Do not replace nested matches with tuple matches when doing so evaluates
something earlier or unnecessarily:

```ocaml
(* Keep this shape if [read_body ic] must not run after a bad header. *)
match read_header ic with
| Error _ as e -> e
| Ok header ->
    match read_body ic with
    | Error _ as e -> e
    | Ok body -> Ok (header, body)
```

This is not an equivalent tidy — it reads the body even when the header fails:

```ocaml
match read_header ic, read_body ic with
| Error _ as e, _ -> e
| _, (Error _ as e) -> e
| Ok header, Ok body -> Ok (header, body)
```

Use passthrough error patterns when they preserve clarity:

```ocaml
match parse s with
| Error _ as e -> e
| Ok v -> validate v
```

Do not replace a readable match with combinator soup. Combinators are good
when they make a short, linear transformation clearer; they are bad when they
hide branching, duplicate work, allocate closures in hot paths, obscure
exceptions, or make debugging harder.

Beware eager arguments:

```ocaml
(* Usually wrong if [default ()] is effectful or expensive. *)
Option.fold ~none:(default ()) ~some:f opt
```

A direct match is often clearer and safer:

```ocaml
match opt with
| None -> default ()
| Some v -> f v
```

## 7. Error handling

Preserve the existing error discipline.

Do not blindly convert: exceptions to `Result`; `Result` to exceptions;
`Option` to exceptions; `invalid_arg` to `failwith`; `raise_notrace` to
`raise`; local `Exit` patterns to combinators.

Keep the distinction between:

| Situation               | Usual mechanism                                |
| ----------------------- | ---------------------------------------------- |
| invalid caller input    | `invalid_arg "message"`                        |
| expected domain failure | `Result` or `Option`                           |
| impossible state        | `assert false`                                 |
| internal bug            | `failwith "context: message"`                  |
| local flow control      | `raise_notrace Exn` or `Exit` with local catch |

Preserve exact error messages unless the user requested wording changes.

Use `assert false` only for states that are unreachable by invariant but not
expressible in the type system. Never use it as a placeholder.

When flow-control exceptions are already used for speed or clarity, keep that
shape unless there is strong evidence the replacement is equivalent and not
slower:

```ocaml
exception Found of int

let find_index p a =
  try
    for i = 0 to Array.length a - 1 do
      if p (Array.unsafe_get a i) then raise_notrace (Found i)
    done;
    None
  with Found i -> Some i
```

## 8. Mutation and state

Default to immutable code, but do not remove mutation when it is the simplest
or fastest correct structure.

Mutation is often right for: tight loop accumulators; buffers and builders;
parsers, decoders, scanners, and state machines; caches and memo tables;
resource lifecycle state; UI or terminal rendering state.

Preserve mutation order and aliasing behavior. Do not turn a mutation-based
loop into list allocation unless performance and semantics are clearly
unaffected.

Keep mutation clustered:

```ocaml
let array_fold f acc a =
  let acc = ref acc in
  for i = 0 to Array.length a - 1 do
    acc := f !acc i (Array.unsafe_get a i)
  done;
  !acc
```

Use records with mutable fields when they model real evolving state. Avoid
scattered refs that make ownership unclear.

## 9. Performance-sensitive code

Be conservative around hot paths.

Assume code may be performance-sensitive when it uses `for`/`while` loops;
`Array`, `Bytes`, `String`, `Bigarray`, `Buffer`; unsafe access; parsers,
lexers, decoders, encoders; render loops or formatting loops; hash tables or
mutable queues/stacks in tight code.

Preserve loop structure, bounds-check assumptions, buffer reuse, allocation
behavior, closure allocation profile, early exits, mutation discipline, and
unsafe access safety conditions.

Do not replace a loop with `List.map`, `List.fold_left`, `Seq`, or chained
combinators in a hot path unless the code already allocates that structure
and the rewrite is clearly equivalent.

Use `::` plus `List.rev` for list accumulation. Never introduce repeated
`acc @ [x]`.

Use `Buffer` for incremental string building and `Bytes` for known-size
construction when that is already the natural structure.

If unsafe access is retained and the invariant is not obvious, add a short
comment explaining the bound, not the syntax:

```ocaml
(* [i] is below [len], and [len <= Bytes.length buf]. *)
Bytes.unsafe_set buf i c
```

## 10. Standard library idioms

Use standard library idioms when they clarify, not to show cleverness.

Good uses: `Option.map` for one obvious transformation; `Option.value` for a
simple default value; `Result.map_error` for a direct error mapping;
`List.exists` / `List.for_all` for short-circuit predicates; `List.rev_map`
when it matches the existing allocation shape; `Buffer.add_*` for incremental
construction.

Prefer a match when branches have names or effects, one branch is
exceptional, evaluation order matters, the default is expensive or effectful,
or the code is easier to debug with explicit cases.

Prefer direct recursion or loops when there is early exit, mutation is
intentional, avoiding allocation matters, multiple accumulators are clearer
when named, or the traversal is domain-shaped rather than list-shaped.

Pipelines are useful for linear transformations, especially three or more
steps. For short expressions, direct calls are often clearer: `f (g x)` is
usually better than `x |> g |> f`.

Do not introduce binding operators, PPX, or new local monadic style unless
the file already uses them and the rewrite is small.

## 11. Formatting style (Bünzli cues)

Formatting should expose structure, not create churn.

First follow the project's formatter and local style. If the project uses
`ocamlformat`, run it on touched files. Do not hand-normalize an entire file
during a narrow tidy pass.

When no formatter convention is clear:

* two-space indentation, no tabs;
* match arms align under `match`;
* keep short `if` expressions on one line when readable;
* break long lines at natural control-flow points: after `->`, before `in`,
  between labeled arguments;
* operators stay at the end of the line they belong to:

```ocaml
let ok =
  long_check x y ||
  alternative_check z
```

* for cascading conditions, keep the happy path flat with `else` at line end:

```ocaml
if d = min then min, (name :: acc) else
if d < min then d, [name] else
min, acc
```

* for longer effectful branches, use `begin ... end` when it improves
  legibility:

```ocaml
if i > max then row0.(m) else begin
  row.(0) <- i;
  rows row row0 (i + 1)
end
```

* semicolons separate side effects; keep sequences short and obviously
  effectful (`let finish c = c.over <- true; c.heap <- Wa.create 0`), and
  break dense semicolon walls into newlines.

## 12. Comments

`.ml` comments are for maintainers of the implementation.

Good comments explain: invariants the type system does not express; why an
unsafe access is safe; why evaluation order matters; why mutation is
required; performance assumptions; tricky error or resource behavior;
non-obvious domain rules.

Bad comments narrate obvious code.

Public documentation belongs in the `.mli` (load `ocaml-doc` for style). Do
not remove existing `.ml` doc comments just for style during a tidy pass.

Use markers consistently with the project: `(* XXX ... *)` for limitations,
`(* FIXME ... *)` for known bugs. Do not add speculative TODOs during
tidying.

## Checklist

Before editing:

* [ ] Read the full `.ml` and nearby `.mli`; identified public vs private
  surface.
* [ ] Identified side effects, exceptions, mutation, I/O, lazy values, and
  likely hot paths.
* [ ] Noted local style; chose the smallest behavior-preserving edit.

While editing:

* [ ] No public API, top-level order, evaluation-order, or
  side-effect-order change.
* [ ] No exception, `raise_notrace`, `Exit`, or error-message change; no
  lazy/strict change.
* [ ] No hidden allocation increase in hot paths.
* [ ] Helpers remain local unless top-level placement is justified.
* [ ] Combinators and pipelines clarify rather than hide control flow.
* [ ] Comments explain invariants or tricky reasoning, not obvious code.
* [ ] No unrelated cleanup or cosmetic normalization.

After editing:

* [ ] Run the formatter on touched files and targeted tests/build when
  available.
* [ ] Review the diff for behavior changes; summarize what was simplified
  and which semantic-risk areas were checked (effects, exceptions, hot
  paths, mutation, public API).

A good tidy diff should feel smaller, clearer, and inevitable.
