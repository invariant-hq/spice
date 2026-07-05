---
description: Designs OCaml library architecture — how a family of modules composes around a narrow waist. Use when designing, reviewing, or restructuring a library's public surface, package layout, extension interface, or bridges to other libraries, and when an API keeps sprouting special-case functions. Triggers on phrases like "design this library", "library architecture", "review the API", "narrow the waist", "simplify the surface", "how should these modules fit together", or "extension interface". For the signature of a single module, load ocaml-module-design instead.
---

# OCaml Library Design

Good OCaml design is not the accumulation of abstractions. It is the
removal of accidental concepts until the remaining types and functions
look inevitable.

A durable library is small, domain-shaped, and compositional: a few
modules arranged around a narrow core that users can combine with other
libraries. Its names are boringly obvious to users who understand the
problem domain. Its combinators let users assemble behavior without
asking the library author for every special case.

This skill covers the multi-module level: the concept graph, the narrow
waist, composition, extension, and packaging. When the question narrows
to one module's signature — its type, constructors, errors, labels —
load `ocaml-module-design` for that part of the work.

The guiding question throughout:

> Does this design make the user's code simpler, more obvious, and more
> correct?

If an abstraction does not answer yes in real workflows, delete it.

## 1. Operating Procedure

Use this workflow for every library design question. Do not skip to a
proposed architecture.

1. **Read the existing surface.** If code exists, read the public `.mli`
   files, callers, tests, and examples before redesigning. Inspect how the
   public modules are used *together*, not just one at a time.
2. **Write user code first.** Sketch 3–5 realistic snippets: getting
   started, the common path, composition, inspection/debugging, and
   extension or integration with another library.
3. **Name the domain concepts.** List the real objects, actions, and
   constraints users already understand. Treat invented coordination
   concepts as suspicious.
4. **List 4–5 strong alternative designs.** Alternatives must change the
   core type, module boundary, error model, description/interpreter split,
   or composition style. Cosmetic renamings do not count.
5. **Evaluate alternatives against the user code.** For each, show the
   resulting caller code and compare concept count, composition, invariants,
   extension path, and common-case friction.
6. **Recommend one design** and explain why it makes the user's code
   simpler, more obvious, and more correct than the alternatives.
7. **Write the concept graph as the product**: the public modules, each
   module's central type, and how values flow between them.
8. **Validate.** Re-run the snippets, check advanced paths are still
   possible, and delete any concept that exists only for the implementation.

The alternatives step is mandatory. Excellent designs come from choosing
between plausible shapes, not from polishing the first one.

## 2. Default Biases

Carry these through every step:

1. **Simplify before abstracting.** Prefer a better core type, module
   boundary, or combinator over a new concept.
2. **Ground concepts in the domain.** Public names should be things users
   already believe exist: readers, slices, paths, commands, codecs, spans.
   Avoid invented mediators — `Manager`, `Handler`, `Context`, `Engine`,
   `View` — unless the domain genuinely has such a thing.
3. **Prefer combinators over feature proliferation.** When specialized
   functions multiply, find the primitive operation and the combinators
   that let users build the variants themselves.
4. **Make common code short and advanced code possible.** The simple path
   must not require understanding extension machinery or interpreters.
5. **Keep the concept budget small.** A new user should learn the library
   by understanding 3–5 primary concepts.
6. **Preserve independence.** Core APIs should be dependency-light,
   I/O-neutral, and concurrency-neutral; integrations live in bridge
   packages or optional modules.
7. **Protect the core boundary.** A feature that serves one caller or one
   backend at the cost of complicating the common API belongs outside the
   core.
8. **Make wrong evolution hard.** If the next feature naturally wants a
   parallel concept, a copied function family, or a bypass around the core
   type, the current design is not stable enough.

## 3. Start From Users and Workflows

Do not start from implementation structure or the current module tree.
Start from the code users should write.

Ask:

- Who are the user groups: application developers, library authors,
  extension writers, tool builders?
- What are the 3–5 end-to-end journeys? Which are common, which advanced?
- What other libraries must this one compose with?

Then sketch the caller's code before designing types. These snippets are
the north star; a design that makes them worse is wrong, regardless of
how clean it appears internally.

```ocaml
(* Transform a byte stream. *)
let reader =
  File.reader file
  |> Zstd.decompress_reads ()
  |> Reader.limit 1_000_000

(* Decode JSON from bytes. *)
let person = Jsont_bytesrw.decode Person.jsont reader

(* Build a command. *)
let cmd =
  Cmd.make (Cmd.info "serve") @@
  let+ port = Arg.(value & opt int 8080 & info ["p"; "port"]) in
  serve ~port
```

Every public function should appear naturally in at least one snippet.
If it does not, treat it as suspicious.

## 4. Model the Domain Before the API

The best APIs feel obvious because they use the user's mental model. List
the real things in the problem domain — objects, actions, states,
constraints, distinctions users already talk about — and compare the
proposed API vocabulary to that list. Good public names come from the
domain; bad ones come from implementation machinery or design anxiety.

```ocaml
(* Domain-shaped. *)
Reader.t   Writer.t   Slice.t   Path.t   Cmd.t

(* Suspicious unless the domain truly has such a thing. *)
Processor.t   Handler.t   Engine.t   Manager.t   Internal_state.t
```

When a design seems to need many helper abstractions, a core concept is
usually missing or mis-shaped:

```ocaml
(* Bad direction: layers around the thing. *)
module Request_spec    module Request_view
module Request_runner  module Request_context

(* Better direction: the thing and its natural operations. *)
module Request : sig
  type t
  val make : ... -> t
  val headers : t -> Headers.t
  val with_header : string -> string -> t -> t
end
```

## 5. Find the Narrow Waist

Every good library has a narrow waist: the type or small family of types
that producers create, transformers preserve, consumers accept, and
bridge packages connect to.

| Domain              | Narrow waist           | Meaning                            |
| ------------------- | ---------------------- | ---------------------------------- |
| Byte streaming      | `Reader.t`, `Writer.t` | Pull or push byte streams          |
| JSON mapping        | `'a Jsont.t`           | A bidirectional JSON/OCaml mapping |
| CLI                 | `'a Term.t`, `Cmd.t`   | Argument computations and commands |
| Time-varying values | `'a signal`            | A value that changes over time     |

Every public item should be classifiable as one of:

* **Constructors** — create the core type from natural sources.
* **Transformers/combinators** — produce a new core value while
  preserving the core type.
* **Eliminators** — consume the core type to produce a result.
* **Bridges** — connect the core type to another library's core type.

An item that fits none of these roles is either standard support
(`pp`, `equal`, `compare`) or a design smell.

A natural pair like reader/writer is fine; the point is that users know
what all composition flows through.

When comparing the 4–5 alternatives from the operating procedure, vary
real axes: the core type (value, function, record, variant, description,
dual pair), the module boundary, the composition unit (functions,
filters, combinators, builders, folds), the effect boundary, and the
error model. The first plausible type is rarely the best; the final type
should make half the API disappear.

## 6. Simplify Before Adding Concepts

When a design feels hard, the next move is usually not another
abstraction.

### The simplification ladder

Try these in order before introducing a new module, type, or layer:

1. **Rename using domain vocabulary.** Confusing names often hide simple
   concepts.
2. **Move functions to the type they operate on.** A misplaced function
   creates artificial coordination.
3. **Merge concepts that always appear together.** If users cannot use A
   without B, A and B may be one concept.
4. **Split concepts with independent lifecycles.** If two states change
   independently, they may need separate types.
5. **Replace special cases with a primitive plus combinators.** Find the
   algebra.
6. **Strengthen the core type.** Encode an invariant so downstream code no
   longer needs checks.
7. **Only then introduce a new abstraction.** It must make real user code
   simpler.

### Concept admission test

A new public concept is allowed only if it passes most of these:

* Users can explain it in domain language.
* It appears in common usage snippets.
* It removes more complexity than it adds.
* It composes with the core type instead of bypassing it.
* Its meaning is stable independent of the current implementation.
* Its absence would force users into boilerplate or invalid states.

If a concept exists mainly to organize your implementation, keep it
private.

### Red flags

Not automatically wrong, but each requires justification:

* A `Spec`/`Descriptor`/`Plan` with only one interpreter that is never
  inspected.
* Separate encode and decode descriptions that can drift apart.
* Many functions named `do_X_with_Y_and_Z` instead of composable `X`,
  `Y`, and `Z` operations.
* A `Context` that only carries optional arguments.
* A module whose functions do not operate on its own `t`.

## 7. Design Composable Operations

Composition is the difference between a small API and an endlessly
growing one.

### Prefer primitive operations plus combinators

Instead of the combinatorial explosion:

```ocaml
val read_file : path -> string
val read_file_limited : max:int -> path -> string
val read_gzip_file : path -> string
val read_gzip_file_limited : max:int -> path -> string
val read_limited_gzip_json_file : max:int -> 'a Json.t -> path -> 'a
```

provide the primitives and let users compose:

```ocaml
val File.reader : path -> Reader.t
val Reader.limit : int -> Reader.t -> Reader.t
val Gzip.decompress_reads : unit -> Reader.t -> Reader.t
val Json_bytes.decode : 'a Json.t -> Reader.t -> 'a

let config =
  File.reader path
  |> Gzip.decompress_reads ()
  |> Reader.limit 1_000_000
  |> Json_bytes.decode Config.json
```

The second design is smaller, more powerful, and easier to extend.

### Filters preserve the waist

A filter wraps or adapts a core value while preserving its type. Keep
the argument order pipeline-friendly: configuration first, transformed
value last.

```ocaml
type reader_filter = Reader.t -> Reader.t

val limit : int -> reader_filter
val tap : (Slice.t -> unit) -> reader_filter
val decompress_reads : unit -> reader_filter
```

### Progressive complexity

Provide simple functions for common cases and precise functions for
advanced cases; never sacrifice the simple path:

```ocaml
val eval : unit t -> Exit.code                          (* most users *)
val eval_value : 'a t -> ('a eval_ok, eval_error) result (* full control *)
```

## 8. Shape the Architecture

### Treat modules as a concept budget

Aim for 3–5 primary modules. More can be fine for a large domain, but
the main path should stay small.

Good signs: each module has one central type; users can explain when to
use each module; common workflows touch only a few; extension authors
have a clear place to plug in.

Bad signs: two modules always appear together; a module contains mostly
functions over another module's `t`; users must understand internals
before the common case; the architecture diagram is clearer than the API
snippets.

### Separate core, effects, and integrations when it helps

* Pure types, invariants, and combinators live in the core.
* I/O, concurrency, and external dependencies live in interpreters,
  adapters, or optional packages.
* Bridge packages connect two independent cores without forcing either
  to depend on the other:

```ocaml
jsont          (* JSON mapping descriptions, no byte-stream dependency *)
bytesrw        (* byte readers/writers, no JSON dependency *)
jsont_bytesrw  (* bridge: encode/decode JSON through readers/writers *)
```

Do not split packages reflexively: if there is only one realistic effect
model and splitting makes every user pay ceremony, keep the API
together. The goal is independence, not fragmentation.

### Accept functions or small interfaces, not frameworks

Do not make the core own a concrete runtime, channel, file descriptor,
or event loop unless that is the domain. Prefer functions or a small
value interface that bridges can implement:

```ocaml
(* Better core boundary than depending on a concrete channel type. *)
val of_read : (bytes -> off:int -> len:int -> int) -> Reader.t
```

Concrete effects belong at the edge:

```ocaml
module Reader_unix : sig val of_fd : Unix.file_descr -> Reader.t end
module Reader_eio : sig val of_flow : #Eio.Flow.source -> Reader.t end
```

This is the mechanism that keeps independent libraries composable.

### Design bridges, not mutual dependencies

A bridge translates between established waists and should be small:

```ocaml
val decode : 'a Json.t -> Reader.t -> ('a, Json.error) result
val encode : 'a Json.t -> Writer.t -> 'a -> (unit, Json.error) result
```

It should not introduce a new central concept unless composition itself
has domain substance.

### Uniform extension patterns

When the library supports extensions, every extension should expose the
same shape — users learn the pattern once:

```ocaml
module type COMPRESSION = sig
  val compress_reads : ?params:Params.t -> unit -> Reader.t -> Reader.t
  val decompress_reads : ?params:Params.t -> unit -> Reader.t -> Reader.t
  val compress_writes : ?params:Params.t -> unit -> Writer.t -> Writer.t
  val decompress_writes : ?params:Params.t -> unit -> Writer.t -> Writer.t
end
```

Inconsistent names or argument orders across extensions are design bugs.

### Extensible errors for families

Where extensions introduce new error cases, extensible variants keep the
core open — but require a printing story; an extensible error without a
uniform diagnostic path is incomplete:

```ocaml
type error = ..
type error += Invalid_checksum of string
val pp_error : Format.formatter -> error -> unit
```

## 9. Use Description/Interpreter Designs Deliberately

A value-level language of inert descriptions with separate interpreters
is one powerful pattern, not the default answer.

Use it when most of these hold:

* There are multiple interpreters, or realistically will be (a CLI term
  is parsed, documented, completed, and evaluated; a codec encodes,
  decodes, and generates schemas).
* The description is inspectable, transformable, or optimizable.
* Composition at the description level is simpler than at the execution
  level.
* Separating definition from interpretation removes dependencies or
  effects from the core.

Avoid it when most of these hold:

* There is only one operation: build then immediately run.
* The description type merely wraps a function.
* Users never inspect, transform, or reuse descriptions.
* The API forces a `compile`/`run`/`eval` step that adds no domain value.

Test:

> If deleting the description type and accepting a function makes common
> code simpler without removing important capabilities, delete the
> description type.

Do not mistake indirection for elegance.

## 10. Expected Output

When answering a library design question, produce the reasoning, not
just the final structure:

1. Summarize the current API and the workflows it serves: public modules,
   apparent core concept, the constructor/transformer/eliminator/bridge
   role of each item, and concepts that look implementation-shaped.
2. Show the desired user snippets.
3. List 4–5 strong alternatives and compare them against those snippets.
4. Recommend one design and state what it deletes, merges, moves,
   preserves, and enables.
5. Present the concept graph: the public modules, their central types,
   and how values flow between them. Delegate individual `.mli` shaping
   to `ocaml-module-design`.
6. Re-run the snippets against the design and state remaining tradeoffs,
   rejected concepts, and extension/integration paths.

If you cannot write realistic user snippets or meaningful alternatives,
say what information is missing instead of inventing a confident design.

## Checklist

* [ ] Existing code, callers, tests, and adjacent modules were read.
* [ ] Desired user code and 4–5 strong alternatives were written first.
* [ ] The narrow waist can be stated in one sentence, and common
  workflows compose through it.
* [ ] The main concept budget is small enough for a new user to hold;
  modules correspond to domain concepts, not implementation layers.
* [ ] Every public item is a constructor, transformer, eliminator,
  bridge, or standard support for the core type.
* [ ] New abstractions were admitted only after the simplification
  ladder failed.
* [ ] Core APIs accept values, functions, or small interfaces instead of
  owning concrete frameworks or runtimes.
* [ ] Bridges connect independent libraries without new central concepts;
  extensions follow uniform naming and argument order.
* [ ] Description/interpreter splits are justified by multiple
  interpreters or inspection, not by habit.
* [ ] The API is smaller than the design it replaces, or the added
  surface clearly pays for itself.
* [ ] A user who understands the domain would find the library
  unsurprising.
