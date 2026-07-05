# AGENTS.md

spice is the ocaml coding-agent.

## important rules

- never run `dune clean`.
- never use the `--force` argument.
- never run dune build with `DUNE_CACHE=disabled`.
- never try to remove the dune lock file.
- never git checkout or reset any file unless explicitly requested.
- never preserve, migrate, or add compatibility for old APIs or old data formats
  unless the user explicitly requests compatibility in the current task. For
  redesigns, delete obsolete concepts and make old shapes fail loudly.
- never hide warnings and never hide unused variables by adding an underscore.
  treat warnings as errors that need a real fix.
- do not use opam, we use dune package management. invoke dune directly to build and test.

## api design rules

- prefer solving API design problems with composition and small combinators
  before introducing wrapper types, service objects, registries, or managers.
- a type is a domain concept. Moving a type into an existing module does not
  remove the concept; it only changes where the concept is named.
- choose `type` versus `module` by the operations the concept needs. If a type
  has public constructors, accessors, validation, comparison, parsing,
  formatting, codecs, or other functions, give it its own module.
- use transparent records or variants only when callers benefit from directly
  constructing and pattern matching on the data and there are no meaningful
  invariants or operations to protect.
- do not introduce a new abstraction to group data that existing types and
  composable functions can express clearly.
- use exceptions only for impossible or programmer-local invalid construction,
  such as invalid static identifiers in provider definitions. At boundaries
  that read user input, config files, environment variables, stores, composed
  provider sets, permissions, or other runtime state, use structured
  `(value, error) result` errors.
- keep recoverable errors structured. Provide `message`/`pp` for CLI and
  diagnostics, but do not make callers or tests depend on parsing human-readable
  strings.

## test guidelines

- host-level tests SHOULD NOT be unit tests, they should be blackbox integration tests
  testing user facing behavior and contracts.
