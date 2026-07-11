# Headless runs

`spice run` runs sessions without the TUI, for scripts, automation, and CI.
The headless surface is a product contract: exit codes and the JSONL event
stream are meant to be depended on.

```sh
spice run "Add an .mli for lib/user.ml and fix the resulting errors"
echo "Summarize the diagnostics" | spice run -
spice run resume --last "Now update the tests"
```

`spice run PROMPT` is shorthand for `spice run start PROMPT`. A subcommand
must be the first argument after `run`; a prompt that collides with a
subcommand name can be passed after `--` (`spice run -- resume`).

## Run flags

| Flag | Meaning |
| --- | --- |
| `--json` | Print JSONL execution events instead of human progress. |
| `--model provider/model` | Model selector for this run. |
| `--reasoning EFFORT` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. |
| `--mode MODE` | Workflow mode: `build`, `plan`, or `review`. |
| `--permission MODE` | Permission preset override (`default`, `accept-edits`, `plan`, `bypass`). |
| `--permission-unattended POLICY` | `block` parks the session and exits 3; `deny` records a model-visible denial and continues. |
| `--sandbox MODE` | `read-only`, `workspace-write` (default), `danger-full-access`, or `external-sandbox`. Restricted modes fail closed when unenforceable. |
| `--require-sandbox` | Fail before credentials and session creation unless the sandbox is enforceable. |
| `--ephemeral` | Persist nothing: the session lives under a throwaway root removed when the run ends. A blocked ephemeral run cannot be resumed. Start only. |
| `--skill NAME` | Load a skill into the turn ahead of the prompt. Repeatable. Start only. |
| `--no-skills` | Disable skill discovery and the skill tool for this invocation. |
| `--no-instructions` | Disable global and project instruction files for this invocation. |
| `--no-project-instructions` / `--project-instructions` | Disable or force-enable project instruction files for this invocation. |
| `--goal TEXT` | Pursue a build-mode goal across turns. Without `PROMPT`, the objective seeds the first turn. Start only. |
| `--goal-budget TOKENS` | Stop goal pursuit when its token budget is exhausted. |
| `--max-steps N` | Maximum model/tool steps. |
| `--cwd DIR` | Working directory override. |
| `--id ID` / `--title T` | New session id and title. Start only. |

See [Instructions and skills](instructions-and-skills.md) for discovery,
precedence, and the difference between cataloged and forced skills.

`spice run resume [SESSION | --last] [PROMPT]` accepts the same run flags:
with `PROMPT` it starts a new turn on the saved session, without it it
advances a blocked or interrupted turn. To reopen a session interactively,
use `spice resume` instead.

## Workspace trust

Headless runs never prompt for or infer workspace trust. An unknown or
explicitly untrusted workspace remains useful, but ambient project config,
instructions, skills, notices, and automatic Dune/Merlin/Git integration stay
disabled. Spice prints one diagnostic with the canonical root and current
state, then continues with user-owned inputs and ordinary tools.

Automation that wants project customization must establish the durable decision
explicitly before the run:

```sh
spice trust /path/to/project
spice run --cwd /path/to/project "PROMPT"
```

`--permission-mode bypass` does not activate project customization, and there
is no per-run trust shortcut. `spice untrust` records a persistent restricted
choice rather than returning the workspace to the interactive unknown state.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Runtime error. |
| 2 | Invalid command input. |
| 3 | The session is blocked on user action and can be resumed. |
| 124 | Command-line parsing failed. |
| 125 | Unexpected internal error. |

Exit code 3 is the load-bearing one for automation: it means the run stopped
on purpose — a permission review, a plan proposal, a question — and the
session is parked, resumable, with nothing lost.

## Resolving a blocked session

When a run exits 3, Spice prints the exact continuation. `spice run reply`
feeds one decision into the blocked session, targeting the pending item by
id:

```sh
spice run reply ID --allow PERMISSION_ID          # allow once
spice run reply ID --allow-session PERMISSION_ID  # allow for the session
spice run reply ID --deny PERMISSION_ID --message "use dune instead"

spice run reply ID --approve-plan
spice run reply ID --reject-plan --message "split the module first"

spice run reply ID --question CALL_ID --answer "yes, target 5.5"
spice run reply ID --tool-interrupted EXECUTION_ID --reason "hung"
```

`--message`, `--answer`, and `--reason` accept `-` to read stdin. In fully
unattended contexts, choose the policy up front with
`--permission-unattended block|deny`.

## Long-running goals

`--goal` asks a build-mode run to continue across turn boundaries until the
goal is completed, blocked, budget-limited, or explicitly stopped:

```sh
spice run --goal "Port the parser and keep the suite green"
spice run --goal "Finish the release" --goal-budget 200000 \
  "Start by auditing the remaining blockers"
```

Goal lifecycle actions use `spice run reply` but do not require a pending
permission, plan, or question:

```sh
spice run reply SESSION --pause-goal
spice run reply SESSION --edit-goal "Ship the parser without compatibility"
spice run reply SESSION --resume-goal [--goal-budget TOKENS]
spice run reply SESSION --clear-goal
```

Pausing and clearing do not start a turn. Resuming a paused, blocked, or
budget-limited goal continues pursuit when the session is idle.

## JSONL events

With `--json`, each line is one event object carrying `schema_version`
(currently `1`), a `type`, and type-specific fields. Event types:

- `session.started`, `session.waiting`, `session.failed`
- `run.started`
- `turn.started`, `turn.finished`
- `tool.started`, `tool.finished`
- `permission.requested`, `permission.resolved`
- `compaction.started`, `compaction.model_started`, `compaction.retrying`,
  `compaction.installed`, `compaction.skipped`, `compaction.failed`
- `workspace.degraded`
- `goal.set`, `goal.objective_updated`, `goal.resumed`, `goal.paused`
- `goal.blocked`, `goal.budget_limited`, `goal.completed`, `goal.cleared`

`session.waiting` describes what the session is blocked on and how to resolve
it; pair it with exit code 3 in scripts.
