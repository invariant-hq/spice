# Architecture

Spice is split into small libraries around a few narrow boundaries. Pure
libraries define checked values and state transitions; the host composes them
with configuration and runtime capabilities; the CLI and TUI drive the same
host protocol and render its facts.

This page describes relationships that span libraries. Individual types and
functions are documented in their `.mli` files.

## Layering

The principal layers are:

| Layer | Responsibility |
| --- | --- |
| Domain libraries | Pure values and transformations for paths, workspaces, LLM requests, permissions, sessions, protocol messages, diffs, reviews, and mutation facts. |
| Adapters | Interpret domain values at an external boundary: provider transports, Dune, OAuth, Git, the filesystem, and platform sandboxes. |
| Host | Resolve configuration, credentials, models, workspace posture, tools, persistence, notices, and turn execution. |
| Products | The CLI and TUI submit protocol commands and render protocol events, saved session projections, and host diagnostics. |

Dependencies should point inward toward values. A pure library does not read
configuration or acquire a filesystem, process, clock, network, credential, or
store capability. An adapter receives the capabilities it needs explicitly.

## One model turn

`Spice_provider` contains static provider and model declarations. It annotates
provider-neutral identities from `Spice_llm`; it does not read credentials,
configuration, or the network.

The host resolves a configured model selector against those declarations,
resolves a credential separately, and asks the provider's host adapter to build
a `Spice_llm.Client.t`. The client interprets a provider-neutral
`Spice_llm.Request.t` through the provider's wire protocol.

The turn path is:

```text
static provider declarations + effective config
                    |
                    v
          host model/account resolution
                    |
                    v
         provider-neutral LLM client
                    |
                    v
protocol command -> session runner -> request/stream/response
                    |
                    v
             protocol events
```

Provider transports see the LLM identity and neutral request options, not the
whole provider catalog or host configuration. Model-dependent decisions belong
at the narrowest layer that has the required facts: catalog metadata is
resolved by the host, neutral request parameters travel in
`Spice_llm.Request.Options`, and wire-only differences stay in the provider
transport. Unrelated decisions are not accumulated in a shared model-profile
object.

## Protocol, session, and host

`Spice_protocol` is the pure command/event language shared by clients and the
host. A client asks with `Command.t`; the host reports progress and durable
facts with `Event.t`; `Outcome.t` says whether the command finished or stopped
at a boundary requiring another command.

`Spice_session` owns the durable session document and semantic event log. Its
pure replay state reconstructs the checked model transcript, active turn,
permission grants, pending tool claims, compactions, and waiting boundaries.
It does not own a model client, scheduler, executable tool runtime, or store.

`Spice_session_store` persists whole session documents with optimistic
revisions, atomic replacement, and cross-process and intra-process writer
serialization. It treats session bytes as opaque: session semantics stay in
`Spice_session`.

`Spice_host.Run` assembles the effectful workspace runtime. Its ordering is
deliberate:

1. `Run.plan` gates the resolved sandbox and combines it with the permission
   posture before credentials or session state are touched.
2. `Run.start` loads context and skills, starts notice producers, and creates
   workspace-scoped services without resolving a model or credential.
3. `Run.runner` binds one turn's mode, model, and credentialed client to the
   assembled workspace.
4. The CLI or TUI drives the runner with protocol commands and renders protocol
   events.

The model and credential are turn facts. Re-resolving them for a later turn
lets a login or model switch take effect without rebuilding the workspace
runtime.

## Executable tools

`Spice_tool` defines a runtime-independent executable tool as a typed input
decoder, permission planner, handler, and typed-output encoder. Dispatch has two
steps: decode once, then inspect permission requests before running that same
decoded call. Permission planning and execution therefore cannot disagree
about the input.

`Spice_tools` contains the concrete file, search, edit, shell, web, and OCaml
tools. Typed evidence remains attached to the erased tool output so host code
can record mutations and render trustworthy status without parsing
model-visible text.

The host builds a catalog from the resolved workspace, sandbox, model, and
skills. A read-only sandbox omits native mutating and code-executing tools from
the catalog. The shell tool remains present because its command is interpreted
through the sealed command sandbox.

Host tools such as questions, plans, todos, goals, and subagents are protocol
operations rather than `Spice_tool` executables. Their state belongs to the
host/session workflow, not to the workspace-tool catalog.

## Paths and filesystem authority

The path stack separates syntax, addressing, and observation:

```text
Spice_path          normalized portable lexical syntax
     |
Spice_workspace     pure addresses under admitted workspace roots
     |
Spice_workspace_fs  filesystem observation and mutation guards
```

`Spice_path` does not know whether a path exists or belongs to a workspace.
`Spice_workspace` resolves input into typed workspace addresses without reading
the filesystem. `Spice_workspace_fs` is the effect boundary: it checks
realpath containment when dereferencing addresses, refuses symlink escapes, and
protects top-level `.git` and `.spice` metadata from native mutation tools.

The command sandbox independently protects the same metadata names inside its
writable roots. Sharing the names makes the native edit path and the shell path
enforce the same authority boundary, while their implementations remain
separate.

## Permission, sandbox, and trust

These are three different controls:

- `Spice_permission` decides whether a trusted description of an operation is
  allowed, denied, or requires review. It is pure policy and grants no runtime
  capability.
- `Spice_sandbox` confines command-bearing tool and integration processes and
  records enforcement evidence. It does not decide whether an operation should
  be attempted or whether project customization should activate.
- `Spice_host.Trust` decides whether ambient project configuration,
  instructions, skills, notices, and built-in tooling may activate. It grants
  no tool permission and does not weaken sandbox confinement.

Native workspace operations are fixed product allowances because their typed
implementations enforce the workspace boundary. Ordinary command execution is
credited only when its permission fact proves project reads and restricted
networking through the sealed sandbox, or records an explicitly selected
external boundary. Read-all, network-enabled, direct, and escalated routes do
not receive that credit. A narrow high-impact review rule precedes command
credit as an accident interlock.

Trust resolves once while configuration loads. Every ambient consumer reads
that immutable value, so an unknown or explicitly untrusted workspace can
still use ordinary file and model tools while project-owned inputs remain
unopened and automatic project processes remain stopped. Interactive startup
may persist a decision and reload once before constructing the normal app;
headless startup never infers trust.

The complete user-visible behavior is documented in
[`manual/security.md`](manual/security.md).

## Durable mutations and review

Session events describe the model/tool conversation. Workspace mutation facts
are a separate durable log in `Spice_mutation`: checkpoints, file changes, and
reverts are correlated with sessions, turns, and tool claims but are not added
to `Spice_session.Event`.

Concrete mutating tools produce `Spice_tools.Receipt` evidence. The host lowers
that evidence to content-addressed mutation facts and stores file bytes in its
blob store. Session diff and revert commands consume this host-owned record.

`Spice_review` is another pure state machine. It describes a feature snapshot,
review marks, CR occurrences, cursor, and verdict. `Spice_review_git` is the
Git worktree adapter that loads a snapshot; the TUI renders and drives the pure
review state. Conservative refresh rules discard review state when content
identity cannot prove that it is still valid.

## Error boundaries

Programmer-local invalid construction raises `Invalid_argument`. Runtime
boundaries return structured errors. Durable workflow conditions are recorded
as session/protocol facts rather than flattened into terminal diagnostics.

The project-wide classification and propagation rules are documented in
[`dev/error-model.md`](dev/error-model.md), including fatal exception handling
and background-fault containment.
