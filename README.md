# Spice

**The OCaml coding agent.**

Spice is a coding agent specialized for OCaml. Instead of treating your code
as plain text, it works with the language's semantics and tooling: it watches
Dune diagnostics while it edits, navigates code through Merlin, edits syntax
trees rather than strings when that is safer, picks up `CR` review comments
you drop in the source, and ships with built-in skills for OCaml development
workflows. The result is an agent that converges faster, produces changes
that compile, and needs less babysitting than a generic agent pointed at an
OCaml codebase.

> **Status: experimental.** This is a first public release. The core loop
> works and we use Spice on Spice daily, but interfaces, configuration, and
> session formats will change without notice. Expect rough edges and please
> report them.

## Why an OCaml agent?

Spice is opinionated by design. The premise is that a coding agent
specialized to one language and its ecosystem can be dramatically more
productive than a generic agent: it knows the build system, the tooling, the
idioms, and the failure modes, and it gets language-level feedback that plain
text tools cannot provide.

But specialization is only half of the story. Our goal is to build the safest
and most productive coding agent there is, and OCaml is the strongest target
for that goal:

- **The language is built for machine-checkable correctness.** A sound type
  system, expressive static types, and explicit module interfaces mean the
  agent gets strong, immediate, trustworthy feedback on every change — far
  more signal than "it seems to run".
- **The ecosystem has a culture of correctness.** Typed build rules,
  property-based testing, and documentation-as-contract give the agent rich
  verification loops to work inside.
- **It is the strongest path to a formal-verification-first agent.** Through
  the Rocq ecosystem and its deep integration with OCaml, we can push the
  agent beyond "compiles and passes tests" toward producing formally verified
  code by default where it matters.

## What makes Spice different

### The build loop is the agent loop

Spice connects to your running Dune instance over RPC and pushes compiler
errors and warnings into the agent loop as they happen. This is not an
after-the-edit check on the file the agent just touched: the host watches the
whole workspace — builds, diagnostics, file changes, review comments — and
injects whatever changed before every model request. The agent sees the
fallout of its own edit before taking the next step, and a clean diagnostic
set — not "the edit applied" — is its baseline for calling a change done.

### Code review lives in the source

Spice speaks the `CR` review-comment convention. Drop a comment in the code —

```ocaml
(* CR spice: this validation belongs in Spice_path, not here *)
```

— and the workspace watcher delivers it to the agent live, mid-session:
feedback anchored to the exact code it is about, with no need to interrupt
the agent or rebuild context in a prompt. The agent addresses the comment and
resolves it as `XCR`; `CR-soon` defers work without losing it. A dedicated
interface for CR-based review of agent changes is coming next.

### Tools that understand OCaml

Alongside the usual file, search, and shell tools, the model gets
OCaml-native tools:

- `ocaml_dune_describe` — a semantic description of the project from Dune
  metadata: libraries, executables, dependencies, tests.
- `ocaml_docs` — the API surface (signatures and documentation) of OCaml code
  by name or path, across your workspace libraries and locked dependencies,
  instead of reading whole files.
- `ocaml_find_definitions` / `ocaml_find_references` — identity-based
  navigation through Merlin, not textual grep.
- `ocaml_ast_edit` — syntax-aware edits addressed by compiler AST location;
  replacement fragments are parsed before the file is written, so a fragment
  that does not parse is rejected instead of corrupting the file.
- `ocaml_eval` — evaluate toplevel phrases in the project's context.
- `ocaml_dune_diagnostics` — the current compiler and Dune error set, on
  demand.

### Token-efficient by construction

Spice adopts the editing and context optimizations pioneered by agents like
Dirac: anchored line edits that stay valid across whitespace and repetition,
exact-string edits for small changes, atomic multi-file patches, and
host-side suppression of redundant file reads with freshness tracking. The
agent spends its context on your problem, not on re-reading files.

### OCaml skills built in

Spice ships with opinionated skills for OCaml work — testing, documentation,
module and library design, FFI, performance, benchmarking, debugging, project
setup, and code tidying — so the agent follows good ecosystem practice with
zero configuration. Project-local skills in `.spice/skills` (and existing
`.claude/skills` or `.agents/skills`) are picked up automatically.

### Safe by default

- Permission presets (`default`, `accept-edits`, `plan`, `bypass`) with
  durable, inspectable rules (`spice permission list`).
- Sandboxed execution modes (`read-only`, `workspace-write`,
  `danger-full-access`) that fail closed when the platform cannot enforce
  them (`spice sandbox status`).
- Workspace trust: project configuration only applies after an explicit
  `spice trust`.
- Every session records what changed: `spice session diff` and
  `spice session revert` undo agent work turn by turn.

## Install

Prebuilt binaries are available for macOS (Apple Silicon and Intel) and
Linux (x64 and arm64, fully static):

```sh
curl -fsSL https://raw.githubusercontent.com/invariant-hq/spice/main/scripts/install.sh | sh
```

The installer verifies the download against the release checksums and
installs to `~/.local/bin` (override with `SPICE_INSTALL_DIR`; pin a
version with `SPICE_VERSION=X.Y.Z`).

Or with Homebrew:

```sh
brew install invariant-hq/tap/spice
```

On Windows, use WSL and the Linux binary.

### Building from source

Spice uses Dune package management — you need a recent Dune (3.22+), and
`dune pkg lock` provisions the OCaml compiler (5.5+) and all dependencies.

```sh
git clone https://github.com/invariant-hq/spice.git
cd spice
dune pkg lock
dune build
```

Run it from the checkout with `dune exec spice --`, or install it on your
`PATH` with `dune install --prefix ~/.local`.

## Getting started

Authenticate with a provider (Anthropic, OpenAI, and Google are supported,
via OAuth or API key):

```sh
spice auth login anthropic
spice auth status
```

Then start the interactive agent in your project:

```sh
cd ~/my-project
spice
```

## Usage

Bare `spice` opens the terminal UI; type `/` for the command palette
(`/model`, `/plan`, `/sessions`, ...). `spice run` runs headless sessions
for scripts and CI:

```sh
spice run "Add an .mli for lib/user.ml and fix the resulting errors"
spice run resume --last "Now update the tests"
```

Headless runs are a product contract: `--json` emits a schema-versioned
JSONL event stream, and when a run blocks on a permission or a question,
Spice exits with code 3 and prints the exact command to resume it, so
unattended runs stay scriptable.

Sessions persist per workspace under `.spice/` (add it to your
`.gitignore`); `spice session diff` and `spice session revert` inspect and
undo agent changes. Configuration is layered JSON; `spice config show
--origins` prints the effective configuration and where each value came
from.

The [manual](doc/manual/README.md) covers the details:
[interactive TUI workflows](doc/manual/interactive.md),
[providers and accounts](doc/manual/providers.md),
[instructions and skills](doc/manual/instructions-and-skills.md),
[configuration](doc/manual/configuration.md),
[security](doc/manual/security.md),
[sessions](doc/manual/sessions.md), and
[headless runs](doc/manual/headless.md).

## Where we're going

Spice is the agent layer of [Invariant](https://invarianthq.dev/)'s
stack, and it is heading in three directions:

1. **Local-first agents.** We think a coding agent should be like your build
   system: a developer tool you run locally, not a luxury product gated
   behind someone else's API. We are building
   [Raven](https://github.com/raven-ml/raven) as the foundational layer for
   model runtimes, and Spice will provide local models built in, with no
   external integration required. An experimental local DeepSeek runtime
   already ships in the provider catalog as a first step.

2. **Push OCaml specialization as far as it goes.** Measure real-world
   productivity and code quality with **SpiceBench**, our benchmark for
   agents on OCaml projects; grow an agent-friendly developer toolbox — the
   [windtrap](https://github.com/invariant-hq/windtrap) testing framework,
   the thumper benchmarking framework, a linter, and more; connect the agent
   to a living OCaml knowledge base, including ecosystem library knowledge;
   and encode development workflows — design review, documentation,
   benchmarking — as runtimes that guide and constrain the agent.

3. **Formal verification.** From the tooling to the model, we want Spice to
   be the safest agent there is: when appropriate, it should default to
   producing formally verified code, building on Rocq and its OCaml
   integration.

## Contributing

Spice is early and moving fast. The most useful contributions right now are
bug reports and real-world usage feedback —
[open an issue](https://github.com/invariant-hq/spice/issues). The
[documentation index](doc/README.md) links the user manual, architecture, and
maintainer references.

## License

Spice is distributed under the ISC license. See [LICENSE](LICENSE).
