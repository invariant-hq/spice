# Error model

Spice classifies failures by who can act on them and whether they belong to the
durable workflow. Keep errors structured until the product boundary that can
render useful recovery guidance.

## The three classes

### Programmer errors

Programmer errors are invalid construction from trusted code or states that
should be impossible after validation. Examples include an empty static
provider id, duplicate declarations in a statically assembled catalog, or an
invalid argument passed to a smart constructor by host code.

These failures raise `Invalid_argument` or expose an internal-error branch at a
boundary that cannot raise. They are not ordinary recovery paths. Fix the
caller or the violated invariant; do not catch the exception to continue.

Input that came from a user, file, environment variable, provider, or store is
not programmer-local merely because it eventually reaches the same
constructor. Decode and validate it at the boundary, returning a structured
error instead.

### Recoverable boundary errors

Boundary errors describe runtime input or state that a caller can repair:

- invalid CLI or configuration input;
- unreadable or malformed config and credential stores;
- unknown providers, models, or reasoning choices;
- missing or blocked credentials;
- unresolved workspaces;
- unavailable required sandbox enforcement;
- storage conflicts and corrupt documents.

Return `(value, error) result` for these conditions. Error variants are the
matching surface for control flow; `message`, `pp`, and diagnostic values are
for people. Tests should match structure below the product boundary and exact
rendering only in black-box product tests.

The host assembly chain uses `Spice_host.Host.Error.t`, grouped by the action a
user must take rather than by the library that first detected the problem. A
host should not expose nested wrapper chains such as
`Run (Session (Store error))`. Inner structured errors may remain as payloads
when they carry useful diagnostic detail, but callers should not have to unwrap
implementation layers to choose a recovery.

Hints are produced where candidate knowledge lives. Model lookup knows the
valid model ids; config parsing knows the supported keys; the outer CLI should
render those hints rather than recreate them.

### Durable workflow facts

Some adverse outcomes are part of the session rather than command-boundary
errors:

- a permission request or denial;
- a tool call that failed or was interrupted;
- a turn that is waiting, failed, or was cancelled;
- a compaction or subagent lifecycle transition.

Represent these as typed session or protocol facts with stable codecs and
replay semantics. The workflow consumes them, the store persists them, and the
CLI or TUI renders them. Do not throw them away by converting them prematurely
to an exception or a terminal diagnostic string.

The same subsystem can produce different classes at different boundaries. For
example, failing to construct a provider client is a recoverable host-assembly
error before a turn starts; a provider call failure during execution is a
structured `Spice_protocol.Error.Provider` returned to the driver; a provider
response successfully accepted into the session becomes durable turn data.

## Propagation rules

Follow these rules when adding a failure path:

1. Validate untrusted input at the boundary where its source is known.
2. Return a structured error if the current caller can recover or report a
   specific action.
3. Record a durable fact if the outcome changes session state or must survive
   replay.
4. Flatten errors at assembly boundaries by recovery path, not source-module
   ancestry.
5. Render once at the product boundary. Do not parse rendered text for control
   flow.
6. Preserve cancellation as cancellation. Do not turn it into a generic
   failure or swallow it in a catch-all handler.

## Diagnostics

`Spice_diagnostic.t` is the common rendering form for user-fixable boundary
errors. It carries a single-line primary message, optional context, and
actionable hints. A module may expose its own `message` or `pp` for direct
users, but product code should prefer the diagnostic assembled at the host
boundary.

Diagnostic text is not stable program input. Stable automation uses exit
codes, JSON/JSONL fields, error variants, and durable session facts.

## Fault containment

Fault containment is the fallback for failures that escaped the expected error
transport above. It does not turn exceptions into a second recoverable-error
API. Fix faults at their source and keep containment at the few effect
boundaries that can preserve a valid session.

Backtrace recording is application policy, not library policy. `bin/main.ml`
enables it once at process entry so both headless commands and the TUI carry a
diagnosable trace. Libraries must not mutate this process-global runtime knob.

### Fatal path

While the TUI runs, Matrix owns uncaught-exception and terminating-signal
handling. It restores the terminal before the default OCaml exception handler
prints the exception and recorded backtrace on the primary screen. Headless
commands use the default OCaml handler directly. Uncatchable failures such as
`SIGKILL` and operating-system OOM termination remain outside Spice's error
model.

Do not add a second Spice-specific crash-file format, signal stack, or exit-code
scheme around this path. Correct the boundary that lost or hid the original
exception information.

### Non-fatal seams

An exception from one background activity must not tear down an otherwise valid
session. Current containment boundaries are:

| Boundary | Fault behavior |
| --- | --- |
| TUI effect thunk | Re-raises Eio cancellation; logs and drops another exception from that effect. |
| Live turn drain | Re-raises teardown cancellation; converts another unexpected exception to `Spice_protocol.Error.Internal`, reports it through the settled result, and keeps the drain loop alive. |
| Live event or settled subscriber | Re-raises cancellation; logs and isolates another exception to that subscriber delivery. |
| Workspace watcher | Publishes a warning or degrades that watcher; the host run continues. |
| Session store | Returns structured corruption and IO errors; invalid persisted data does not escape as a background exception. |

When adding background work, route failure into one of these seams—or an
equivalent explicit degradation—rather than letting an exception escape a fiber
into a shared switch. Preserve cancellation as cancellation at every seam.

### The turn terminal invariant

**A turn that becomes durably active within a `Session_loop.execute` call
reaches a terminal `Turn_finished` event before that call returns — on the
error and exception paths as much as on the ordinary one.**

An error that merely propagates leaves the turn active in the saved session,
and an active turn is not inert: `require_no_active_turn` guards a new turn,
`fork`, `rewind`, `archive`, and `delete` alike, so every later command is
refused against it. The frontend, whose own turn ended with the error, offers
no interrupt — it offers one only while *its* turn is in flight — so nothing
can close it and the session is dead while looking idle. One provider error
was enough.

The invariant lives at the one place turns are driven: `execute` wraps the
model/tool loop and closes an open turn with `Spice_session_run.fail` on the
way out. Two boundaries it must not cross:

- **A cancellation is not a failure.** It surfaces as an ordinary provider
  error *value* (`Spice_llm.Error.Cancelled`), not an exception — the client
  polls the cancel flag mid-stream — and Live keeps that turn active on purpose
  so the queued `Command.Interrupt` finishes it as `Interrupted`. Closing it as
  failed both mislabels the outcome and strands that interrupt, which no-ops
  against a turn that is already closed: the frontend then waits forever on a
  turn that can never settle. The wrapper skips the repair while
  `hooks.cancelled ()` holds.
- **A refused command is not a failed turn.** The command preambles stay
  outside the wrapper, so a stale answer or a start against a waiting turn is
  rejected without destroying the healthy turn it was rejected against.

A new terminal path for turns belongs inside that wrapper, not beside it.
