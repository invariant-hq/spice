---
description: Designs the signature of a single OCaml module — its core type, constructors, eliminators, errors, and invariants. Use when writing, reviewing, or reshaping an .mli, choosing a type representation, or doing API design for one module or a small family of related types. Triggers on phrases like "design this module", "what should the .mli look like", "review this signature", "what type should I use", "how should I expose this", or "API design". For how multiple modules fit together, load ocaml-library-design instead.
---

# OCaml Module Design

A module signature is a contract: the implementation can change, the
`.mli` is forever. Good module design finds the one type whose natural
operations make the signature small, then makes invalid states hard to
express.

This skill covers the single-signature level: shaping `type t`, its
constructors, eliminators, errors, and invariants. When the question
widens to how several modules compose — narrow waists, bridges,
extension interfaces — load `ocaml-library-design` for that part.

The guiding question throughout:

> Does this signature make the caller's code simpler, more obvious, and
> more correct?

## 1. Operating Procedure

Use this workflow for every signature question. Do not skip to a
proposed `.mli`.

1. **Read the existing code.** The current `.mli`, the implementation's
   invariants, callers, and tests. A design that ignores existing
   workflows is speculation.
2. **Write caller code first.** Sketch 3–5 realistic snippets: the
   minimum useful call, everyday usage, composition with other values,
   and inspection/debugging. These snippets are the north star; a design
   that makes them worse is wrong.
3. **Name the domain concept.** What is `t`, in the user's vocabulary?
   Avoid invented mediators (`Manager`, `Handler`, `Context`,
   `Internal_state`) unless the domain genuinely has such a thing.
4. **List 3–5 alternative shapes for the core type**: abstract value,
   function, immutable record, variant, pair of dual types. For each,
   show the resulting caller code.
5. **Recommend one shape** and write the `.mli` as the product. Include
   only items that appear in real workflows or complete the abstraction.
6. **Validate.** Re-run the snippets; delete anything that exists only
   for the implementation.

Ask of every candidate `t`:

* What is `t` in one sentence?
* What invariant does it protect?
* What are its natural constructors, transformations, and eliminators?

If two unrelated types compete for attention, you probably have two
modules. If many functions do not mention `t`, they belong elsewhere.

## 2. Shape the Signature as a Story

A signature should read top-to-bottom: what the type is, its invariant,
how to create it, inspect it, transform it, and consume it.

```ocaml
type t

(* Constructors and constants. *)
val make : ... -> t
val empty : t

(* Conversions. *)
val of_string : string -> t
val to_string : t -> string

(* Observers. *)
val length : t -> int
val is_empty : t -> bool

(* Combinators and transformations. *)
val map : ... -> t -> t
val append : t -> t -> t

(* Eliminators and traversals. *)
val fold : ... -> t -> 'a
val iter : ... -> t -> unit

(* Standard support. *)
val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
val compare : t -> t -> int
```

Not every module needs every section. Provide `pp`, `equal`, `compare`
when real workflows use them — not as reflexive boilerplate.

A right-sized example — small because the type is right, needing no
`Span_view`, `Span_builder`, or `Span_context`:

```ocaml
module Span : sig
  (** A half-open byte range [first, last) within a larger value.
      Invariant: [0 <= first <= last]. *)
  type t

  val make : first:int -> last:int -> t
  val of_length : first:int -> length:int -> t

  val first : t -> int
  val last : t -> int
  val length : t -> int
  val is_empty : t -> bool

  val shift : int -> t -> t
  val contains : int -> t -> bool
  val intersect : t -> t -> t option

  val pp : Format.formatter -> t -> unit
  val equal : t -> t -> bool
  val compare : t -> t -> int
end
```

### Pick the right representation exposure

| Exposure | Callers can                                    | Use when                                                                    |
| -------- | ---------------------------------------------- | --------------------------------------------------------------------------- |
| Abstract | Only use your operations                       | There is an invariant, or the representation may change                     |
| Private  | Inspect/pattern match but not construct freely | Representation is stable, but construction must be validated                |
| Exposed  | Construct and modify freely                    | The type is plain data with no meaningful invariant                         |

Abstract is the default; relax only for a reason. Document the invariant
near the type and validate eagerly in constructors — never let
eliminators observe broken state:

```ocaml
(** A non-empty list.
    Invariant: contains at least one element. *)
type 'a t
```

## 3. Constructors: Natural Sources, Clear Failure Mode

Provide constructors for the values callers naturally have
(`make`, `of_string`, `of_bytes`, …). When construction can fail, choose
the failure mode by the caller's workflow — see section 6. If both a
raising and a safe form are useful, name them so the choice is visible:

```ocaml
val of_string : string -> (t, parse_error) result
val of_string_exn : string -> t
```

Do not wrap every constructor in `result` because it feels safer; for
programmer errors it makes common code noisier without improving
correctness.

A `Builder` earns its place only when construction is genuinely
structured — many typed parts, validation spanning fields, a real
domain language (a codec's object mapping, for instance). For a value
with two or three fields, `val make : first:int -> last:int -> t` beats
a builder pipeline.

## 4. Eliminators and Observers: No View Machinery

Provide ways to consume `t` into the values callers naturally need
(`to_string`, `pp`, `fold`). Missing eliminators force callers to depend
on representation details — and, worse, tempt the designer into wrapper
types.

**Do not introduce observation wrappers.** Types named `X_view`,
`X_info`, `X_facts`, `X_observation`, or `X_snapshot` that re-package a
value's fields are machinery, not design: they add a concept, a
construction step, and a drift risk, and callers still project out the
one field they wanted. The simpler, more elegant design is almost always
direct observers and combinators on `t` itself:

```ocaml
(* Machinery: a wrapper to look at a span. *)
type view = { first : int; last : int }
val view : t -> view

(* Design: the operations callers actually want. *)
val first : t -> int
val last : t -> int
val length : t -> int
val shift : int -> t -> t
```

The test: if callers call the observation function and then immediately
project a field or re-derive a fact, delete the wrapper and export the
observers. If callers need to traverse, give them `fold`; if they need a
derived fact, give it a name (`is_empty`, `contains`); if they need to
combine facts, that is what combinators are for.

The rare exception is a *case analysis* type: when the domain genuinely
decomposes into stable alternatives and pattern matching is the clearest
interface (a JSON tree's `Null | Bool | Number | String | Array |
Object`, an AST). Even then it must survive: the cases are domain
concepts, they stay stable across representation changes, and matching
beats combinators in several real workflows — not one.

The same economy applies to conveniences. Ask of each: is it common
enough to deserve a name? Can callers write it in one line from
primitives? Would adding it invite many siblings? If the last answer is
yes, improve the primitives instead (that is library-level work — see
`ocaml-library-design`).

## 5. Arguments: Labels, Aliases, Optionals

Design names and argument order so call sites explain themselves. Use
labels when they disambiguate same-typed values or make partial
application safer; keep the primary object and pipeline-last values
unlabeled:

```ocaml
val sub : t -> pos:int -> len:int -> t
val blit : src:t -> src_pos:int -> dst:t -> dst_pos:int -> len:int -> unit
```

Type aliases cost nothing and prevent call-site ambiguity when an
ordinary type has a specific meaning:

```ocaml
type pos = int
type length = int
```

Optional arguments are for genuine defaults, and each default must be
documented. Defaults come in three kinds: inherited from a wrapped value
(`?pos` defaults to the reader's position), a sensible constant
(`?slice_length` defaults to 64 KiB), or computed from other arguments
(`?last` defaults to `length - 1`). Add a `unit` terminator when
optional arguments could create partial-application ambiguity:

```ocaml
val compress_reads :
  ?level:int -> ?checksum:bool -> unit -> Reader.t -> Reader.t
```

If optional arguments grow numerous or travel together, introduce a
small parameter type — for real configuration, not for every pair of
optionals:

```ocaml
module Params : sig
  type t
  val make : ?level:int -> ?checksum:bool -> unit -> t
  val default : t
end
```

### Bidirectional descriptions for symmetric serialization

When a type needs both encoding and decoding, a single bidirectional
value prevents the two directions from drifting apart:

```ocaml
val json : t Jsont.t
```

Avoid separate encode/decode APIs unless the directions are genuinely
independent.

### Sentinels for end-of-data

In stream-like APIs where wrapping every return in `option` would cost
allocation and noise, use a distinguished sentinel with physical
equality, and name safe alternatives with the `_or_eod` suffix:

```ocaml
val eod : t              (** The end-of-data sentinel. *)
val is_eod : t -> bool   (** [true] iff [v == eod]. *)

val read : t -> slice        (** Raises on end of data. *)
val read_or_eod : t -> slice (** Returns [eod] at end. *)
```

This keeps the API explicit about where end-of-data is possible without
taxing the common path.

## 6. Error Design

Error design is part of signature design; the wrong error shape can
dominate an otherwise simple API.

### Choose the mechanism by the caller's workflow

* **Exceptions** — invalid arguments, violated preconditions, programmer
  mistakes, impossible states, non-recoverable failures.
* **`result`** — recoverable domain failures the caller is expected to
  branch on: parsing external input, decoding data, protocol and file
  format errors.
* **`option`** — ordinary absence where present/absent is all the caller
  needs.
* **Sentinels** — end-of-data in tight stream APIs (section 5).

```ocaml
(* Programmer error if [first > last]. *)
val make : first:int -> last:int -> t

(* Recoverable: input came from outside the program. *)
val of_rfc3339 : string -> (t, parse_error) result

(* Ordinary absence. *)
val find_opt : key -> 'a t -> 'a option
```

A `result` used for programmer errors is a red flag: it forces callers
to handle a case that indicates a bug, and the handling code is usually
`assert false`.

### Keep errors domain-shaped, with a diagnostic path

An error type should help callers decide what to do next:

```ocaml
type parse_error =
| Unexpected_char of { pos : int; char : Uchar.t }
| Unterminated_string of { pos : int }
| Invalid_escape of { pos : int; escape : string }
```

Avoid `type error = Error of string` unless the module only forwards
opaque errors from another system. Either way, every public error type
needs at least a printer:

```ocaml
val pp_error : Format.formatter -> error -> unit
```

## 7. Enforce Correctness With the Smallest Sufficient Type Tool

1. **Abstract/private types** for representation invariants.
2. **Variants and records** for real domain alternatives and product data.
3. **Phantom types** for lightweight capabilities or states.
4. **GADTs** when the API needs type-level relationships ordinary types
   cannot express clearly.
5. **First-class modules/functors** when module-level abstraction is
   truly needed, not as a substitute for a simpler value API.

Start at tier 1; reach higher only when you can state the gain in one
sentence.

Good phantom use — the capability is real and callers never annotate:

```ocaml
type read
type write
type _ fd

val open_read : path -> read fd
val read : read fd -> bytes
val write : write fd -> bytes -> unit
```

Questionable phantom use — `'state config` with `unchecked`/`checked`
phases whose only meaning is that one function was called earlier, and
which now forces annotations through the common workflow.

Correctness by construction should make caller code clearer. If it makes
the common case contorted, reconsider the boundary.

## 8. Naming and Documentation

Names are part of the type system users carry in their heads. Use
conventional names unless the domain strongly suggests otherwise:

| Pattern             | Meaning                                              |
| ------------------- | ---------------------------------------------------- |
| `make` / `v`        | Primary constructor                                  |
| `of_X` / `to_X`     | Conversion from/to representation `X`                |
| `is_X` / `has_X`    | Predicate                                            |
| `with_X`            | Functional update                                    |
| `map`               | Transform contained values, preserving shape         |
| `fold` / `iter`     | Consume/traverse contents                            |
| `pp`                | Pretty-printer                                       |
| `equal` / `compare` | Structural equality/order                            |
| `*_exn`             | Explicit raising variant when non-raising is primary |
| `*_opt`             | Optional result when absence is ordinary             |
| `*_or_eod`          | Sentinel result for end-of-data APIs                 |

Avoid cute names and non-standard abbreviations.

Doc comments state semantics — invariants, defaults, ownership and
mutation, effects, positioning behavior for streams, and error
conditions (raise vs `result`) — not implementation:

```ocaml
(** [limit n r] returns a reader that exposes at most [n] bytes from [r].
    The underlying reader is left positioned after the bytes actually
    read. *)
```

For full documentation style, load `ocaml-doc`.

## 9. Expected Output

When answering a signature question, produce the reasoning, not just the
final `.mli`:

1. Summarize the current signature and the workflows it serves; flag
   items that look implementation-shaped.
2. Show the desired caller snippets.
3. List the alternative core-type shapes considered and compare them
   against the snippets.
4. Recommend one and state what it deletes, merges, and enables.
5. Present the proposed `.mli`, with invariants documented near the type.
6. Re-run the snippets against it and state remaining tradeoffs.

If you cannot write realistic caller snippets, say what information is
missing instead of inventing a confident design.

## Checklist

* [ ] Existing `.mli`, implementation invariants, callers, and tests
  were read.
* [ ] Caller snippets and alternative core-type shapes were written
  before the signature.
* [ ] The module has one central type (or one tightly related family),
  statable in one sentence.
* [ ] Representation exposure is justified: abstract by default, private
  or exposed for a reason.
* [ ] Invariants are documented near `type t` and enforced by
  constructors.
* [ ] Constructors exist for natural sources; eliminators for natural
  targets; no view/observation wrapper, `Builder`, or `Context` that
  observers, combinators, and `make` would cover.
* [ ] `result` only for recoverable errors; exceptions for programmer
  errors; every error type has `pp_error`.
* [ ] Labels clarify call sites without being mechanical; optional
  arguments have documented defaults.
* [ ] Names follow the conventional table; call sites read without
  upstream documentation.
* [ ] Every public item appears in a real caller snippet or completes
  the abstraction.
