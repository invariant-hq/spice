# Workspace trust and project activation

Status: implementation plan

## Decision

Workspace trust is persistent consent to activate automatically discovered
project customization. It is not permission to perform an operation, and it
is not operating-system authority.

Spice keeps three independent boundaries:

| Boundary | Question it answers |
| --- | --- |
| Workspace trust | May ambient project configuration, instructions, skills, notices, and built-in project tooling participate? |
| Permission policy | May this agent-requested operation proceed? |
| Sandbox and workspace filesystem guards | What authority does the operation actually receive? |

Trust never selects a permission preset, weakens a sandbox, grants an
escalation, installs a project permission rule, changes credential or provider
destinations, or authorizes arbitrary executable definitions. The user or an
administrator remains the only source of those authorities.

The runtime states are:

- `Unknown`: no decision is stored. It has the same safe runtime behavior as
  `Untrusted`, but an interactive frontend may ask for a decision.
- `Untrusted`: the user has persistently declined project customization.
- `Trusted`: project customization may activate, subject to the independent
  permission and sandbox boundaries.

Unknown and untrusted workspaces remain useful. Users can inspect source and
invoke ordinary tools under their selected permission and sandbox posture;
the workspace simply contributes no ambient customization.

## Why this boundary exists

The current trust store is dormant, but the product capability it should own
is not hypothetical.

`Config.load` currently reads both workspace configuration layers
unconditionally. `Context.load` injects project instruction files, `Skills.load`
catalogs project skills, and the TUI prewarms `Run.start` at launch. That
prewarm calls `Producers.start`, which can synchronously execute `dune
describe`, resolve a configured Merlin program, start filesystem observation,
and later launch `dune build --watch`.

There are two concrete authority bugs:

1. `workspace.tooling` defaults to `auto`, so merely opening a Dune workspace
   can run repository-controlled build logic before the user submits a prompt.
2. `ocaml.merlin_program` is accepted from project configuration as an
   arbitrary argv prefix. Merlin and other OCaml command tools spawn host
   processes rather than using the sealed shell sandbox.

The permission posture compounds this. An enforcing workspace-write shell
sandbox currently contributes a general allow-any-non-destructive-command
rule, even though command-bearing OCaml tools do not all execute through that
sandbox. The policy is crediting confinement that the actual executor may not
provide.

Documentation reflects all sides of the contradiction: the README says trust
gates project configuration, while the security manual and CLI say it gates
nothing. The implementation must establish one true semantic before those
surfaces are rewritten.

## Product invariants

The implementation is complete only when all of these invariants hold.

1. No project-controlled process starts while workspace trust is `Unknown` or
   `Untrusted`.
2. `Unknown` and `Untrusted` activate exactly the same runtime capabilities.
   Their only difference is whether an interactive frontend asks again.
3. Project content cannot write its own trust decision. Trust state lives only
   in the user configuration home.
4. Trust is resolved for the discovered project root, canonicalized with
   `realpath`, not the invocation subdirectory. Outside a marked project the
   canonical invocation directory is the root. Trust does not inherit from
   arbitrary filesystem ancestors. Separate worktree roots receive separate
   decisions.
5. Trust is a launch snapshot. A decision changed by another process affects
   the next host load, never half of an existing run.
6. Project configuration remains allowlisted even when trusted. Trust is not a
   reason to accept permission rules, sandbox settings, provider endpoints,
   credentials, shell programs, private-network access, or other user
   authority from the workspace.
7. Project-local configuration has exactly the same authority as committed
   project configuration. Being conventionally gitignored is not proof of
   user ownership.
8. Every subprocess started on behalf of a model tool executes through the
   run's sealed sandbox, whether its permission fact is a command, a path
   access, or another semantic operation. A command permission fact records
   whether that route is proven; callers that cannot prove it remain fail-safe
   and receive no sandbox-derived permission credit.
9. Automatic project processes require workspace trust and execute through the
   run's sealed sandbox, but never create agent permission prompts. They are
   product-owned startup behavior rather than model-requested operations.
10. Headless operation never infers trust from non-interactivity, Git
    membership, filesystem ownership, bypass mode, or a permissive sandbox.
11. Project instructions and skills are gated as ambient instruction channels.
    This reduces automatic prompt-injection exposure but is never described as
    making repository source safe or trusted.
12. A failure to read or decode the user trust store fails closed before project
   inputs activate and produces a structured, actionable diagnostic.
13. Trust-store updates serialize both across processes and across fibers in one
   process. A successful update cannot lose another workspace's concurrent
   decision, and cancellation while waiting for the lock remains responsive.

## User workflows

### Opening an unfamiliar repository

Before entering the normal TUI or starting its prewarm, Spice displays the
canonical project root and offers:

1. **Continue without project customization (remember this choice)** — persist
   `Untrusted` and start the normal TUI with project configuration,
   instructions, skills, notices, and tooling disabled.
2. **Trust and enable project customization (remember this choice)** — persist
   `Trusted`, reload the host, and start normally.
3. **Exit** — make no stored decision and start no project process.

The safe continuation is selected by default. The wording names concrete
effects; it does not claim that trust prevents prompt injection and does not
say that trusting grants file, command, or network permission.

No model lookup, credential lookup, Git command, Dune command, watcher,
project instruction load, or project skill scan happens before the choice.
Pure filesystem discovery of the current directory, `.git` marker, config file
paths, and trust-store state is allowed.

### Returning to an explicitly untrusted repository

Spice starts without prompting. The TUI status surface and `spice config show`
report `untrusted`; a concise diagnostic reports that project customization is
disabled. The user can later run `spice trust DIR` and restart.

### Working in a trusted repository

Spice applies allowlisted project configuration, injects project instructions,
catalogs project skills, enables project-derived notices, and may start the
built-in Dune/Merlin integration. The current permission preset and sandbox are
resolved exactly as they would be in an untrusted workspace.

Arbitrary executable settings remain user-owned. In particular,
`ocaml.merlin_program` is removed from the project allowlist rather than being
made safe by trust.

### Plan and read-only runs

Trust does not override the selected mode. A trusted read-only run may perform
read-only, sandboxed project inspection, but it must not start a build watcher
that needs workspace writes. An untrusted plan or read-only run starts no
project integration at all.

### Headless operation

Unknown and untrusted workspaces run in restricted mode without prompting.
Commands that would normally consume effective project customization emit one
stable diagnostic on stderr and continue. Direct trust, config-file editing,
and inspection commands use their own explicit output and do not add a generic
restricted-mode warning. There is no implicit headless trust and no
`--trust-workspace` shortcut: automation must establish the durable decision
explicitly with `spice trust DIR`.

`--permission-mode bypass` remains unrelated. It can bypass agent permission
review for a run, but cannot activate ambient project inputs.

### Subdirectories, symlinks, and worktrees

`spice trust path/to/repo/subdir` discovers and stores the enclosing project
root. Existing paths are canonicalized through `realpath`, so symlink aliases
converge. A clone at another path and a linked worktree at another root require
their own decisions. Branch or content changes at the same root do not revoke
trust automatically; mutable arbitrary executables therefore require a more
specific approval than workspace trust.

## Alternatives considered

### Delete trust and permission-review every process

This would remove a dormant module, but permission prompts do not express
whether project configuration, high-priority instructions, skills, and notices
may become ambient input. It also makes automatic integrations either
impossible or repeatedly noisy. The product has a real persistent decision to
record, so deleting the concept would move it into scattered ad hoc checks.

### Gate executable integrations only

This preserves benign project preferences, instructions, and skills in
untrusted workspaces. It leaves automatically elevated instruction channels
active, however, and requires every new configuration field to be classified
correctly as inert or effectful. Existing model, backend, instruction, notice,
and executable settings show that this classification is not stable enough to
be the security boundary.

### Gate every project input on one workspace decision

This is the selected design. An untrusted workspace is explicit data available
through tools, never ambient configuration or behavior. The invariant is
simple to explain and audit, while the existing project-config allowlist keeps
trust from becoming authority.

### Per-capability workspace consent

Separate decisions for configuration, instructions, skills, Dune, Merlin,
hooks, and MCP would maximize granularity but introduce a consent matrix,
persistence schema, UI, and evolution policy without distinct current user
workflows. Do not build this registry. Arbitrary future executable definitions
are independently user-enabled because they are different domain capabilities,
not entries in a generic trust matrix.

### Trust or exit

Codex and Claude Code use variants of this startup boundary. It prevents unsafe
activation but makes read-only inspection of unfamiliar repositories
impossible. Spice should keep the strong activation boundary while offering a
useful restricted mode.

## Domain model and module design

The existing `Trust.t` snapshot is implementation machinery: callers load a
map only to pass it back into mutations, there is no query, and two mutations
through one snapshot can overwrite each other. Replace it rather than wrapping
it.

Three smaller API shapes were considered:

- A bare `Unknown | Untrusted | Trusted` result is easy to match but separates
  the decision from the canonical root it describes. Frontends would display a
  second, potentially differently canonicalized path.
- A public map from paths to decisions recreates the stale-store snapshot and
  makes callers responsible for persistence invariants.
- A capability token that trusted consumers must possess encodes activation in
  the type system, but it spreads a new phantom/capability vocabulary through
  configuration, context, skills, and producers without preventing direct
  subprocess mistakes.
- Per-feature activation tokens provide finer granularity but recreate the
  rejected consent registry.

The selected shape is one immutable trust resolution for one canonical root.
It keeps identity and state together, while mutations still re-read the store
instead of accepting a stale snapshot. The abstract representation protects
the canonical-root invariant; the status variant is exposed because its three
cases are stable product vocabulary.

The public module is:

```ocaml
module Trust : sig
  type status = Unknown | Untrusted | Trusted

  type t
  (** Trust status for one canonical workspace root. *)

  module Error : sig
    type t
    val message : t -> string
    val pp : Format.formatter -> t -> unit
  end

  val find :
    stdenv:Eio_unix.Stdenv.base ->
    ?process_env:Env.t ->
    root:Spice_path.Abs.t ->
    unit ->
    (t, Error.t) result

  val trust :
    stdenv:Eio_unix.Stdenv.base ->
    ?process_env:Env.t ->
    root:Spice_path.Abs.t ->
    unit ->
    (t, Error.t) result

  val untrust :
    stdenv:Eio_unix.Stdenv.base ->
    ?process_env:Env.t ->
    root:Spice_path.Abs.t ->
    unit ->
    (t, Error.t) result

  val is_trusted : t -> bool
  val root : t -> Spice_path.Abs.t
  val status : t -> status
  val status_to_string : status -> string
end
```

`find` and both mutations are result-returning boundaries because they read
runtime filesystem state. `trust` and `untrust` reload the store under the
store lock, apply one change, and atomically replace it; callers never hold a
store snapshot. Their result is the canonical resolution frontends render.
`Unknown` is never stored.

`Trust.Error.t` is a domain variant internally, distinguishing invalid roots,
store reads, decoding or unsupported versions, locking, and writes. The public
module keeps the constructors abstract because callers recover identically,
but `message` and `pp` must retain the operation and path. Do not reduce the
error to an unstructured string merely because the first callers only display
it.

`Config.t` gains the already-resolved `Trust.t` and exposes:

```ocaml
val workspace_trust : t -> Trust.t
```

There is no `Workspace_activation`, manager, registry, capability token, or
second policy object. Ambient consumers read the same immutable trust value
from `Config.t`; permission and sandbox code do not depend on it.

### Store format

The user-side store becomes:

```json
{
  "version": 2,
  "workspaces": {
    "/canonical/project/root": "trusted",
    "/canonical/other/root": "untrusted"
  }
}
```

Remove `granted_at`: no behavior or user surface consumes it. Version 1 was a
dormant implementation with no runtime effect, so version 2 deliberately does
not add migration or compatibility. An unsupported version or old value shape
fails loudly with an actionable diagnostic.

Directories created by Spice use `0700`; the trust file, lock file, and
temporary files use `0600`. Do not chmod an existing user-selected
`XDG_CONFIG_HOME`. Mutations use an adjacent user-side lock file and the same
two-level serialization pattern as the session store: an in-process `Eio.Mutex`
keyed by the canonical store path plus a cross-process `F_TLOCK` retry loop with
cancellable clock sleeps. After acquiring both, reload the store, apply one
change, write an exclusive temporary file, rename atomically, and clean up the
temporary on failure. A blocking `F_LOCK` in a systhread is not acceptable
because cancellation cannot interrupt it; a POSIX record lock alone is not
enough because it does not exclude another fiber in the same process.

## Configuration semantics

`Config.load` already validates the cwd and finds the nearest `.git` project
root before reading workspace layers. Consolidate that logic with
`Config_file.discover` so effective loading and `spice trust DIR` cannot derive
different roots. `Config_file.paths` gains a `project_root` observer; this is
existing discovery metadata, not a second workspace abstraction. Immediately
after discovery, `Config.load` calls `Trust.find` for that root and retains the
returned canonical resolution in the effective config. A `Trust.Error.t`
becomes a `Config.Error.t` with its structured diagnostic intact.

For `Trusted`, loading continues through the existing byte cap, parse,
allowlist, rule stripping, and budget-clamping pipeline.

For `Unknown` and `Untrusted`:

- do not open or parse project or project-local config;
- contribute empty workspace layers;
- retain the discovered paths for inspection and editing commands;
- emit a structured `project_config_disabled` warning for each existing
  workspace config file, carrying its `Config.Source` and no field;
- keep all user, extra-file, environment, and runtime override layers
  unchanged.

The warning codec, text renderer, `config show --origins`, and support JSON all
gain this case. Effective config JSON includes `workspace_trust` at the top
level so automation never has to infer activation from warning prose.

`Config_file.load`, `edit`, `ensure`, and explicit `--project` operations remain
available while untrusted. Reading or writing a named file is an explicit user
operation; it does not make the layer effective.

Remove `shared_project` from `ocaml.merlin_program`. Trusted project config may
select whether the built-in workspace integration is on, off, or auto, but the
actual program prefix remains user/extra/env owned. Direct `config set
--project` rejects the field; a pre-existing occurrence is ignored with the
normal forbidden-project-key diagnostic.

## Ambient project consumers

Every consumer uses `Trust.is_trusted (Config.workspace_trust config)` from the
same host snapshot.

### Instructions

`Context.load` always loads built-in/global/user instruction sources according
to user configuration. It discovers and reads project `AGENTS.override.md`,
`AGENTS.md`, `CLAUDE.md`, and related project sources only when trusted.

The context fact surface distinguishes “disabled by workspace trust” from a
missing or invalid instruction file. It may construct the known candidate names
as disabled facts, but it must not stat, walk, or read them. Do not inject a
synthetic model message describing omitted project instructions; report the
restriction to user-facing status and diagnostic surfaces instead.

### Skills

`Skills.load` always loads built-in and user-owned skill roots. It scans
`.spice/skills`, `.agents/skills`, `.claude/skills`, and project compatibility
locations only when trusted. A `skills.paths` entry is classified by its
resolved location, not merely by the config layer that named it: an entry
inside the current project root is disabled while untrusted, including a
relative entry from user config; an absolute root outside the project remains
available. This closes the ambient project-input path without disabling
explicit user libraries elsewhere.

An untrusted project cannot activate a skill by duplicating a user skill name.
Do not scan project skill directories merely to enumerate disabled candidates.
`spice skills list/show` omits them and emits one trust diagnostic, following
the command's existing output style.

### Notices and automatic probes

Untrusted workspaces do not start CR-comment observation, Dune diagnostics,
Dune build notices, project filesystem notices, or project health probes.
Trusted workspaces retain the user-configured notice switches.

The TUI home brief must not run its automatic Git discovery/glance commands in
an untrusted workspace. Explicit review commands remain explicit user actions
and are not redefined as ambient activation.

### Mutation recording

The Git-tree mutation backend executes Git as an implementation detail. In an
untrusted workspace, use the non-Git mutation log and do not perform automatic
Git discovery. In a trusted workspace, run mutation-backend Git commands
through the same sealed sandbox used by the run.

### Dune and Merlin producers

`Producers.start` receives the effective sandbox in addition to the host and
derives:

```text
engaged = workspace is trusted
          and workspace.tooling resolves to on/auto-for-Dune
```

When not engaged it performs no Dune capture, Merlin warm-up, build watch,
project CR scan, or project fswatch spawn. Read-only mode never starts the
mutating build watcher: use `Sandbox.mutating_tools` for that decision rather
than starting it and waiting for the read-only sandbox to reject its writes.
Read-only mode may attempt Dune describe or an already-resolved Merlin binary
through the sealed read-only sandbox; any resolution path that needs to mutate
the workspace degrades without an unsandboxed retry.

Trusted Dune describe, build-watch, and Merlin processes are prepared through
`Spice_sandbox.spawn` before the lower-level process API receives argv or
environment. A sandbox refusal is a structured degraded-tooling result, never
an unsandboxed fallback.

## Permission and process semantics

### Credit only a proven sealed command route

Command permission facts carry a small domain-shaped execution-route value:
`Sandboxed` when the exact operation is known to use the run's sealed sandbox,
and `Direct` otherwise. Construction defaults to `Direct`; confinement is never
inferred from a tool name, command text, or the presence of a sandbox elsewhere
in the run.

Under an enforcing `workspace-write` posture, sandbox-backed policy first
reviews destructive commands, then allows non-destructive commands whose route
is `Sandboxed`. This restores routine Dune, Merlin, search, evaluation, and
shell workflows without prompt flooding while keeping `Direct` commands
reviewable. Read-only, danger-full-access, external-sandbox, and unavailable
backends contribute no workspace-write command credit.

The existing order remains authoritative: explicit durable rules precede the
preset and sandbox-backed rules, exact session grants apply only after those
rules, and Plan mode's command denial is never relaxed. Shell escalation stays
a separate custom access and therefore remains reviewable even when the
ordinary command fact is sandboxed.

### Confine every command-bearing standard tool

Permission review and sandboxing remain separate: approval permits an attempt,
then the sandbox confines or refuses it.

Thread the host-sealed `Spice_sandbox.t` from `Toolset.make` into every standard
tool subprocess, including Dune describe, OCaml evaluation, Merlin-backed
type/docs/definition/reference tools, glob/search helpers implemented by `fd`
or `rg`, and their resolution/warm-up paths. This audit is wider than
`Permission.Access.argv`: a fixed implementation helper can inherit process
authority even when the user-facing permission fact is a path read. Make the
sandbox argument required at production tool constructors; do not use an
optional permissive default.

Add one private process helper in `spice_tools` that:

1. validates a non-empty argv with `Spice_sandbox.Argv`;
2. calls `Spice_sandbox.spawn` with the exact environment;
3. executes only `Spawn.argv` and `Spawn.env`;
4. returns a structured sandbox refusal without spawning;
5. preserves timeout, cancellation, process-group termination, and bounded
   output behavior.

The shell keeps its explicit escalation path, which deliberately uses filtered
environment without confinement only after the separate escalation access is
approved. No OCaml or project-tooling path gains an unsandboxed fallback.

The `spice_ocaml_dune` library remains independent of `spice_sandbox`. Its
process entry points accept a small required preparation function supplied by
the host/tools bridge; they do not acquire a host sandbox dependency or invent
a sandbox manager.

Audit every `Permission.Access.argv` constructor against its execution path and
every direct process spawn under `lib/host`, `lib/tui`, `lib/tools`, and
`lib/ocaml`. Classify each surviving spawn in the implementation commit: model
tool, trusted automatic integration, or explicit user/frontend operation.
Model tools and trusted integrations must use the sealed sandbox; explicit
front-end operations such as opening a login browser need not masquerade as
model tools but must be documented at their actual authority boundary. The
final tree must have no model-tool subprocess whose executor bypasses the
sealed sandbox, and no automatic project process whose activation bypasses
trust.

## Interactive startup sequencing

The trust decision is a preflight, not a normal permission dialog and not a
chat surface.

`Tui.Runtime.run` performs this sequence:

1. Load a host snapshot. Unknown trust is already restricted, and host loading
   performs no project process or credential operation.
2. If trust is `Unknown`, display a dedicated startup trust prompt before
   creating the normal app, building the home brief, or arming the run prewarm.
3. When the prompt chooses `Untrusted` or `Trusted`, persist that choice and
   reload the host once so all later consumers observe the stored state.
   A workspace that loaded with either persisted state bypasses this step.
4. On exit, return successfully with no session and no prewarm.
5. Create the normal TUI, snapshot, brief loaders, and prewarm only from the
   resolved host.

Use a small `Trust_prompt` module with a pure choice state and rendering plus a
thin terminal driver. It is intentionally not added to `App.surface`: doing so
would require a live host swap throughout the long-running app merely to solve
a one-time launch decision. The prompt runs before alternate-screen ownership,
leaves its decision visible in scrollback, handles EOF as exit, and accepts
`1`, `2`, `3`, arrows plus Enter, Escape, and Ctrl+C consistently.

The first choice is initially highlighted. Enter persists `Untrusted`; Escape,
EOF, and Ctrl+C exit without writing a decision. A persistence or reload
failure stays in the preflight with an actionable error and must not fall
through to a partially initialized app. The prompt is shown even when the run
requested permission bypass: the decisions are independent.

When tests supply a Matrix directly, their workspace trust must be seeded
explicitly. Do not introduce a hidden “assume trusted in tests” environment
variable. A PTY test exercises the real unknown-workspace prompt.

## CLI and inspection surfaces

### `spice trust` and `spice untrust`

Both commands discover the same project root as `Config.load`, mutate the
current store under lock, and print the canonical recorded root. `untrust`
stores `Untrusted`; it does not delete the entry and recreate a prompt loop.
Remove every dormant-feature note.

The commands use `Config_file.discover` plus its `project_root` observer; they
must not call full `Config.load`, because an unrelated user-config error should
not prevent repairing workspace trust and because the command does not need an
effective configuration.

Running from a subdirectory must affect the root. Repeating the same decision
is a no-op. Store and path failures use `Trust.Error` diagnostics.

### `spice config`

- `show` and `show --origins` include `workspace_trust`.
- Unknown/untrusted effective output contains no workspace-layer values.
- Direct project-file reads and writes remain possible and explain that changes
  activate only in a trusted workspace.
- Project config help no longer lists `ocaml.merlin_program`.

### `spice doctor`

Doctor reads the trust store, reports its path and validity, resolves the
current project root, and reports `unknown`, `untrusted`, or `trusted`. It does
not contact a provider or start project tooling.

### TUI status

Replace the current `trust: not enforced` fact with the resolved state and
canonical root. The home/footer shows one concise restricted-workspace warning;
it does not repeat one warning per disabled input.

## Future executable integrations

Workspace trust must not silently bless arbitrary hooks, MCP servers, plugins,
credential helpers, environment mutation, or project-selected executables.

When those features are introduced:

- workspace trust may allow their definitions to be discovered;
- local commands require approval bound to a normalized command/configuration
  digest, and changed content requires reapproval;
- remote servers require explicit user-owned import/enablement and may not
  acquire bearer tokens or environment-derived headers from workspace config;
- plugins remain user-installed and user-enabled;
- project policy may deny or require review, but cannot add authority.

Do not expand the meaning of a historic path-wide trust grant when adding one
of these capabilities.

## Verification strategy

Host-level behavior is verified primarily through the real CLI/TUI binaries.
Unit tests are reserved for pure policy or codec laws that cannot be observed
more cheaply through a black-box workflow.

### Trust and configuration black-box cases

- Unknown workspace project and project-local config do not affect effective
  values.
- Persisted `Untrusted` has identical effective behavior and does not prompt on
  the next interactive launch.
- Persisted `Trusted` activates allowlisted values.
- Permission rules, sandbox settings, provider endpoints, web enablement, and
  other forbidden keys remain ignored while trusted.
- `ocaml.merlin_program` is rejected from both project layers.
- A user-configured relative `skills.paths` entry inside the project is disabled
  while untrusted; an absolute user skill root outside it remains active.
- Trusting from a subdirectory stores the canonical project root.
- Symlink aliases converge; separate worktree roots do not.
- `untrust` persists an explicit refusal.
- Concurrent trust updates to different roots do not lose either decision.
- Concurrent same-process fiber updates do not lose either decision, and a
  cancelled lock waiter terminates promptly.
- Invalid version, malformed JSON, non-directory paths, permission errors, and
  failed atomic rename all fail with actionable diagnostics and leave the
  previous store intact.

### Activation black-box cases

- A fake `dune` on `PATH` writes a marker if spawned. Starting TUI/headless in
  unknown and untrusted Dune workspaces never creates the marker.
- The unknown-workspace TUI prompt itself creates no marker before a choice.
- Choosing untrusted enters the normal TUI without a marker.
- Choosing trusted permits the expected Dune probe only after persistence and
  host reload.
- Unknown/untrusted fake-provider transcripts contain no project instructions
  and advertise no project skills; trusted transcripts contain them.
- Project CR comments and project-derived notices are absent while untrusted.
- Headless unknown runs continue restricted, print the stable diagnostic, and
  never prompt or activate tooling.

### Permission and sandbox cases

- Workspace-write no longer auto-allows a generic command access.
- Native workspace edits retain their intended sandbox-backed credit.
- Routine Dune, Merlin, search, evaluation, and shell commands whose sealed
  route is proven do not prompt under enforcing workspace-write.
- A direct or otherwise unproven command remains reviewable.
- Destructive commands and shell escalation remain reviewable even when the
  ordinary command route is sealed.
- Read-only, danger-full-access, external-sandbox, and unavailable backends
  contribute no workspace-write command credit.
- Fixed-command glob/search fixtures also execute through the sealed sandbox,
  despite exposing path permissions rather than command permissions.
- After approval, an OCaml/Merlin/Dune fixture may write inside allowed
  workspace roots but cannot write a marker in a protected/outside directory.
- A forced unavailable sandbox produces a refusal and performs no spawn.
- Read-only trusted mode never starts `dune build --watch`.
- Explicit shell escalation remains the only reviewed path that can drop Spice
  confinement.

### TUI cases

- Snapshot/PTY coverage for all three choices, safe default selection, keyboard
  navigation, EOF, Escape, and persistence failure.
- Trusted and untrusted launches bypass the prompt.
- No session document is created when the user exits.
- Settings and footer surfaces show the resolved state without stale launch
  data.

### Harness migration

The existing suites assume project customization is active. Preserve that
assumption explicitly instead of adding a production “trust tests” escape
hatch:

- the cram setup writes a valid trusted decision for the testcase's canonical
  root before commands run;
- trust-specific cram cases create a nested repository root and an isolated
  config home, so exact-root trust does not leak into them;
- the in-process TUI project harness uses the public `Trust.trust` operation to
  seed its temporary root before `Runtime.run`;
- the real PTY trust tests deliberately omit that seed.

This keeps unrelated snapshots stable while ensuring the new boundary is
exercised through the same store and discovery code as production. Do not add
an environment variable that makes unknown workspaces trusted.

### Commands

Run focused cases during each commit, then finish with:

```sh
dune build @all
dune runtest
```

Do not run `dune clean`, disable Dune's cache, remove its lock, hide warnings,
or weaken a failing test.

## Implementation sequence and commits

Each semantic change is independently reviewable and carries its tests. The
plan document is committed separately before implementation.

1. **`fix(permission): Stop crediting command confinement globally`**
   - Remove command rules from `Permission.Preset.sandbox_backed_rules`.
   - Update policy documentation and focused permission tests.
   - Preserve native workspace-write credits.

2. **`fix(tools): Confine command-bearing tool processes`**
   - Add the private sandboxed-process primitive.
   - Require and thread the sealed sandbox through every standard tool
     subprocess, including fixed `rg`/`fd` helpers.
   - Add the process-preparation bridge to Dune describe/watch entry points.
   - Prove refusal/no-spawn and outside-write confinement.

3. **`feat(host): Record explicit workspace trust decisions`**
   - Replace the snapshot store API and schema.
   - Consolidate project-root discovery and serialize mutations correctly.
   - Update the trust/untrust CLI around the canonical resolution.

4. **`feat(host): Enforce workspace trust for project activation`**
   - Expose the resolved trust value on `Config.t`.
   - Disable workspace layers, instructions, skills, notices, automatic Git
     probes/mutation discovery, and producers unless trusted.
   - Remove project ownership of `ocaml.merlin_program`.
   - Pass the effective sandbox into trusted producers.
   - Add CLI/config/activation black-box tests.

5. **`feat(tui): Ask before activating project customization`**
   - Add the startup preflight and three-choice UX.
   - Reload once after persistence, before snapshot/brief/prewarm construction.
   - Update test harness seeding and add PTY coverage.

6. **`fix(permission): Credit only proven sandboxed commands`**
   - Add the execution route to existing command permission facts, defaulting
     to direct/unproven.
   - Target the narrow sandbox-backed allow rule at the sealed route after the
     destructive-command review rule.
   - Thread sealed-route evidence from every standard sandboxed subprocess tool
     and ordinary shell execution; keep escalation separate.

7. **`docs(security): Define the workspace trust boundary`**
   - Align README, architecture, security, configuration, CLI help, doctor,
     settings facts, and performance notes.
   - State the three independent boundaries and headless behavior.
   - Remove every dormant or “safe project config loads unconditionally” claim.

If a phase reveals that a process cannot be confined without a substantially
larger redesign, keep the command permission review fix, disable that automatic
integration, record the limitation explicitly, and do not ship an unsandboxed
fallback.

## Acceptance criteria

The feature is ready when:

- opening or running against an unknown repository executes no project process
  and consumes no ambient project input;
- users can continue productively without trusting;
- a persisted trust choice is applied to the canonical project root and is
  visible everywhere the effective posture is inspected;
- trusted project configuration remains unable to widen user/admin authority;
- every enabled project process is trust-gated and routed through the sealed
  sandbox (which may be deliberately unconfined only when the user selected
  `danger-full-access` or declared an external boundary);
- ordinary commands are auto-approved only when their sealed execution route
  is proven and an enforcing workspace-write posture supplies the matching
  credit;
- TUI, headless, config, doctor, instruction, skill, notice, and tooling
  behavior agree;
- focused black-box cases, `dune build @all`, and `dune runtest` pass.
