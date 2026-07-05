---
description: Writes and reviews OCaml API documentation, with `.mli` doc comments as the source of API truth and longer guides as Markdown under `doc/`. Use when documenting, improving, or auditing OCaml interfaces — module summaries, section structure, contracts, cross-references, errors, invariants, examples, odoc formatting — and whenever writing or editing doc comments in an `.mli`. Triggers on phrases like "document this module", "write the docs", "docstrings", "odoc", "API reference", "tutorial", "cookbook", or "Bunzli style".
---

# OCaml API Documentation

Write OCaml documentation as a compact API contract. The `.mli` explains the
observable semantics of the interface: what values mean, what functions return,
which invariants hold, which errors occur, which effects happen, and how the API
is meant to compose.

A coding agent reading the `.mli` should know the intended path through the API:
which values to construct, which combinators to compose, which functions are
low-level or advanced, which errors are recoverable, and which lifetime,
mutation, ownership, effect, or performance constraints matter.

Do not write marketing prose, implementation narration, or tutorials in API
comments. This skill covers documenting an interface; for designing the
interface itself, load `ocaml-module-design`.

## 1. Operating procedure

Before writing or revising documentation:

1. Read the relevant `.mli`, `.ml`, callers, tests, examples, README, and
   existing `doc/*.md` files.
2. Identify the reader:
   - public module: users of the library and coding agents consuming the API;
   - internal module: maintainers preserving invariants and extension points.
3. Infer the API concept, intended workflows, error model, invariants, and
   composition points.
4. Choose a documentation strategy. Use the smallest one that lets the reader
   use or maintain the API correctly:
   - terse `.mli` contracts only;
   - richer module overview plus compact value docs;
   - concept-first module documentation;
   - reference docs plus `doc/tutorial.md` or `doc/cookbook.md`;
   - internal maintainer docs focused on invariants and extension points.
5. Decide what belongs in `.mli` and what belongs in `doc/*.md`.
6. Organize the `.mli` by concept. Document types before values when possible.
7. Write contracts in canonical odoc forms.
8. Review for precision, brevity, navigability, and whether a coding agent
   would use the API as intended.

If exact behavior cannot be inferred, inspect implementation and tests. If it
is still unknown, do not invent a contract; report the uncertainty to the user.

## 2. Where documentation lives

### `.mli`: API reference and source of truth

The `.mli` contains module summaries and conceptual organization; public types,
invariants, aliases, sentinels, and units; public values and their contracts;
exceptions, result errors, absence cases, and recovery paths; section anchors
and cross-references; and minimal examples only when they clarify a contract.
It should be complete enough to use the API correctly without reading the
implementation.

### `doc/*.md`: longer material

Use Markdown files under `doc/` for material that would bloat the reference:
tutorials and quick starts, recipes and multi-step examples, architecture
notes, design rationale, migration guides, extended error handling guides.

Create only the pages that are warranted. Do not introduce `.mld` pages unless
the repository already uses them and the user explicitly asks for that format.

### `.ml`: no odoc API comments

Do not add odoc documentation comments to `.ml` files. Use the implementation
only to infer observable contracts for the `.mli`.

## 3. Audience

### Public modules

Write for library users and coding agents. Emphasize what the abstraction
represents, the intended construction and composition path, stable semantics
and edge cases, precise error behavior, and which APIs are advanced,
low-level, unsafe, or debugging-only. Do not expose internal representation or
current implementation strategy unless it is part of the public contract.

### Internal modules

Write for maintainers. Emphasize invariants that must be preserved, extension
points and expected laws, ownership/mutation/lifetime assumptions, and the
boundary between stable and changeable behavior. Even internal docs state
observable facts, not incidental code narration.

## 4. Voice and canonical sentence forms

Use direct, technical, declarative prose.

Prefer: `is`, `maps`, `returns`, `raises`, `errors`, `formats`, `mutates`.

Avoid: "This function ...", "Used to ...", "Allows you to ...", "tries to
...", "handles ...", "basically ...", marketing language, and implementation
storytelling.

Canonical forms:

```ocaml
(** [field x] is ... *)

(** [is_empty x] is [true] iff ... *)

(** [compare x y] orders ... The order is compatible with {!equal}. *)

(** [make ...] is ... Raises [Invalid_argument] if ... *)

(** [pp ppf x] formats ... *)

(** [find k m] is [Some v] if [k] is bound to [v] in [m] and [None]
    otherwise. *)
```

Use one-line docs for simple values. Reserve longer comments for real
contracts.

## 5. Odoc conventions for `.mli`

* Inline OCaml code: `[code]`
* Terminology or emphasis: `{e term}`
* Scoped labels: `{b Warning.}`, `{b Note.}`, `{b Tip.}`
* OCaml code blocks: `{[ ... ]}`
* Unordered lists: `-`; ordered lists: `+`
* Ranges: `\[[a];[b]\]`; exponents: `{^53}`

Prefer inline prose for errors; do not use `@raise` tags.

Cross-reference related API instead of repeating explanations: `{!make}`,
`{!M.make}`, `{!type:t}`, `{!module:M}`, `{!module-type:S}`,
`{!exception:Error}`. Use simple references when unambiguous and
kind-qualified ones when needed. Use "See also ..." as a final paragraph only
when it improves navigation.

For Markdown guides, either use the repository's established link convention
or write the path plainly, for example `doc/errors.md`. Do not invent links
that the documentation build cannot render.

## 6. Module and section structure

### Module docstring

Start every public `.mli` with a module-level docstring: a one-sentence
summary; an optional compact explanation of the concept and terminology; the
intended entry points or related modules; and links to relevant `doc/*.md`
pages when longer material exists.

```ocaml
(** Immutable maps from keys to values.

    Maps preserve the ordering of their keys according to {!Key.compare}.
    Construct maps with {!empty}, {!singleton}, or {!of_list}; query them with
    {!find} and compose updates with {!update}.

    See also doc/cookbook.md for common update patterns. *)
```

For internal modules, the module docstring states the invariant or maintenance
role:

```ocaml
(** Internal representation of normalized paths.

    Maintainers must preserve the invariant that separators are canonical and
    no segment is empty. Public constructors enforce this invariant. *)
```

### Sectioning

Organize by concept, not alphabetically or mechanically. Use stable anchors —
they are part of the public documentation surface; do not rename them during
routine edits.

Common section names:

| Title                      | Anchor         | Contents                                 |
| -------------------------- | -------------- | ---------------------------------------- |
| Types                      | `types`        | core types, aliases, units               |
| Constructors               | `constructors` | `make`, `v`, `create`, `of_*`            |
| Queries                    | `queries`      | accessors, predicates, lookup            |
| Predicates and comparisons | `predicates`   | `is_*`, `equal`, `compare`               |
| Updating                   | `updating`     | setters, mutation, persistent updates    |
| Iterating                  | `iterating`    | folds, iterators, callbacks              |
| Converting                 | `converting`   | `of_*`, `to_*`, parsing, encoding        |
| Formatting                 | `formatting`   | `pp`, debug printers, inspectors         |
| Errors                     | `errors`       | exceptions, error types, helpers         |
| Low-level API              | `low-level`    | advanced or representation-sensitive API |

```ocaml
(** {1:types Types} *)
(** {1:constructors Constructors} *)
```

### Includes and re-exports

Guide odoc output for re-exported signatures:

```ocaml
include module type of Stdlib.Bytes (** @closed *)
```

Use `(**/**)` only to hide true internals, not to avoid documenting public
API.

## 7. Documenting types

Document types before values when the values depend on their meaning.

**Abstract types** — one-sentence concept plus the invariants users need. Do
not reveal the representation unless it is part of the contract.

```ocaml
type t
(** The type for normalized file paths. Values contain no empty segments. *)
```

**Type aliases** — document aliases that carry semantics: units, ranges,
sentinels, lifetimes, encodings, validity requirements.

```ocaml
type byte_pos = int
(** The type for byte positions. A zero-based byte offset. *)
```

**Sentinels and absence** — name and define sentinels exactly. If absence is
represented by `option`, state both cases for key operations.

```ocaml
val byte_pos_none : byte_pos
(** [byte_pos_none] is [-1]. It denotes the absence of a byte position. *)
```

**Variants and records** — document the concept and each constructor or
field. For records, state field units, ownership, mutation, and optionality
when not obvious.

```ocaml
type sort =
| Null (** Null values. *)
| Bool (** Boolean values. *)
| Number (** Numeric values. *)
(** The type for JSON value sorts. *)
```

**Extensible variants** — explain who extends the type, when, and how cases
compose.

```ocaml
type error = ..
(** The type for stream errors. Stream formats extend this type with their
    own decoding errors. *)
```

## 8. Documenting values

Start with `[name args]` and state the meaning. Do not restate the type
signature unless the names are needed for the contract.

**Constructors** — what is constructed, accepted inputs, invariants
established, and errors:

```ocaml
val make : bytes -> first:int -> length:int -> t
(** [make b ~first ~length] is a slice of [b] over byte indexes
    \[[first];[first + length - 1]\].

    Raises [Invalid_argument] if [length < 0] or if the interval is not within
    [b]. *)
```

**Optional arguments** — state defaults and behavioral consequences; use a
list when there are multiple knobs:

```ocaml
(** [create ?strict ?buffer_size r] is a decoder reading from [r] with:
    - [strict], whether malformed input is rejected. Defaults to [true].
    - [buffer_size], the input buffer size in bytes. Defaults to [4096].

    Raises [Invalid_argument] if [buffer_size <= 0]. *)
```

**Predicates, comparisons, lookup** — use logical wording and state absence
behavior. If equality ignores fields, say so.

```ocaml
(** [is_empty t] is [true] iff [t] has no bindings. *)

(** [get k m] is the binding of [k] in [m].

    Raises [Not_found] if [k] is unbound. *)
```

**Iterators, callbacks, and resources** — document both sides of the
contract: what the API guarantees and what the callback must guarantee.

```ocaml
(** [with_file p f] opens [p] and calls [f ic]. The channel [ic] remains valid
    only during the call to [f] and is closed before [with_file] returns,
    including if [f] raises. *)

(** [make read] is a reader backed by [read]. The contract is:
    - [read b ~off ~len] writes at most [len] bytes in [b] at [off].
    - [read] returns [0] only at end of input.
    - The reader never calls [read] after end of input. *)
```

**"Like X but ..." variants** — only when the difference is exact and small:

```ocaml
(** [of_bytes_or_empty] is like {!of_bytes} except that empty intervals are
    returned as {!empty}. *)
```

**Formatters** — say what is formatted and for whom; avoid "pretty-prints":

```ocaml
(** [pp ppf t] formats [t] for users. The output is stable across patch
    releases. *)

(** [pp_dump ppf t] formats [t]'s internal shape for debugging. The output is
    not stable. *)
```

## 9. Errors, exceptions, and edge cases

Every API should have a clear error story.

**Exceptions** — state exact raising conditions. Avoid "may raise" unless the
behavior is intentionally nondeterministic; then state the source of
nondeterminism.

```ocaml
val decode_exn : string -> t
(** [decode_exn s] is the value encoded by [s].

    Raises [Error e] if [s] is not a valid encoding. *)
```

**Results** — state the success case, error case, error shape, and diagnostic
path:

```ocaml
val decode : string -> (t, error) result
(** [decode s] is [Ok v] if [s] encodes [v] and [Error e] otherwise.
    [e] contains the byte position and expected grammar item. *)

val error_message : error -> string
(** [error_message e] is a human-readable message for [e]. It is not stable
    enough for programmatic matching. *)
```

**Absence and boundary cases** — document them as part of the contract:

```ocaml
(** [first t] is [None] iff [t] is empty. *)
```

**Unspecified behavior** — if behavior is intentionally outside the contract,
say so narrowly. Do not use "unspecified" to hide behavior that should be
part of the contract.

```ocaml
(** The order of callbacks is unspecified. Clients must not depend on it. *)
```

## 10. Invariants, lifetimes, mutation, effects, performance

Document these only when they affect correct use or API choice.

* **Invariants** live where the type is introduced; repeat only when a value
  establishes or relaxes one.
* **Lifetimes and ownership**: state whether returned values are views,
  copies, borrowed buffers, or owned values.

```ocaml
(** [window t] is a view of [t]'s current buffer. The view remains valid until
    the next call that reads from [t]. *)
```

* **Mutation and effects**: state observable mutation, I/O, global state,
  caching, and concurrency constraints.

```ocaml
(** [clear t] removes all bindings from [t]. Existing iterators over [t]
    become invalid. *)
```

* **Performance**: include complexity, allocation, streaming, or blocking
  behavior only when it matters, and prefer scoped facts over broad promises.

```ocaml
(** [find k m] is the binding of [k] in [m], if any. It runs in [O(log n)]
    where [n] is the number of bindings in [m]. *)
```

## 11. Modules, module types, and functors

**Nested modules** — document the module's role and when to use it:

```ocaml
module Cursor : sig
  (** Mutable cursors over immutable buffers. Cursors are low-level; prefer
      {!fold} unless incremental traversal is required. *)
end
```

**Module types** — document required laws and semantics, not just member
names:

```ocaml
module type ORDERED = sig
  type t
  (** The type being ordered. *)

  val compare : t -> t -> int
  (** [compare x y] is a total order on [t]. It must be compatible with
      structural equality used by clients of the resulting map. *)
end
```

**Functors** — document the meaning of the result, requirements on the
argument, and side effects of application if any:

```ocaml
module Make (Key : ORDERED) : S with type key = Key.t
(** [Make (Key)] is a map implementation whose keys are ordered by
    [Key.compare]. The correctness of lookup and update depends on
    [Key.compare] being a stable total order. *)
```

## 12. Examples and Markdown guides

In `.mli`, include examples only when they disambiguate a compact contract,
and keep them short:

```ocaml
(** [normalize p] removes redundant separators and current-directory segments.

    For example, [normalize "a//./b"] is ["a/b"]. *)
```

Move multi-step examples, tutorials, recipes, migration walkthroughs, and
anything requiring setup or build instructions to `doc/*.md`.

Suggested pages when warranted — do not create a page set mechanically:

* `doc/tutorial.md`: concept and first complete use;
* `doc/cookbook.md`: common patterns and recipes;
* `doc/errors.md`: error interpretation and recovery;
* `doc/design.md`: rationale and extension points;
* `doc/migration.md`: version-to-version changes.

Each recipe states the problem, gives the minimal code, and links back to the
relevant API names. Markdown examples should be runnable or clearly labeled
as fragments, in fenced code blocks with languages (`ocaml`, `sh`, `json`).

## 13. Anti-patterns and replacements

* "This function returns the result" → `[f x] is ...`
* "Used to ..." / "Allows you to ..." → state the operation as a contract.
* "May raise ..." → `Raises [E] if ...`
* "Tries to parse ..." → state `[Ok v]` and `[Error e]` cases.
* Hidden invariant → document it with the type.
* Long example in `.mli` → move to `doc/*.md` and reference it.
* Alphabetical order → concept order.
* Implementation narration → observable semantics.
* Repeating the same explanation → define once, link elsewhere.

## Checklist

* [ ] The intended reader is clear: public user or internal maintainer.
* [ ] The documentation strategy is the smallest adequate one, with longer
  material in `doc/*.md` and no odoc comments in `.ml` files.
* [ ] The module docstring gives a compact concept and intended entry points.
* [ ] Public items are organized by concept with stable anchors.
* [ ] Every public type, value, exception, module, and module type has a doc
  comment, unless intentionally hidden from odoc.
* [ ] Abstract types state their concept and user-visible invariants;
  semantic aliases state units, ranges, or validity constraints.
* [ ] Value docs start with `[name args]` and state precise behavior,
  including defaults for optional arguments.
* [ ] Exceptions and result errors state exact conditions and the diagnostic
  path; absence cases are documented.
* [ ] Mutation, effects, lifetimes, and performance notes appear exactly when
  they affect correct use.
* [ ] Low-level, unsafe, advanced, or debugging-only APIs are marked as such.
* [ ] No filler phrases remain, and no contract depends on incidental
  implementation details.
* [ ] A coding agent reading only the `.mli` would choose the intended API
  path.
