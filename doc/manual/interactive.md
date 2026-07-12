# Interactive TUI

Running `spice` without a command opens the terminal UI. The TUI is the main
interactive product: it keeps the conversation, tool activity, workspace
status, decisions, and saved sessions in one keyboard-driven surface.

```sh
cd ~/project
spice
```

Press `?` on an empty composer to see the shortcuts available in the current
surface. That sheet is authoritative for individual keys; this guide explains
the workflows behind them.

## Repository activation preflight

Before opening the normal TUI in an unknown workspace, Spice names the
canonical repository root and asks whether to activate repository config,
instructions, skills, Dune rules, local tools, evaluator access, and Build-mode
project processes. This preflight runs before session creation,
alternate-screen ownership, home-brief construction, or any project process.

The choices are:

1. continue restricted and remember `untrusted`;
2. trust and activate the repository;
3. exit without saving a decision.

The restricted choice is selected by default. Use `1`–`3` or arrows and Enter;
Escape, Ctrl+C, and EOF exit without writing. A persistence error remains in the
preflight for retry. Activation does not approve operations or weaken the
selected sandbox.

Choosing trust saves the decision and reloads the host once. If project
activation fails, Spice restores the workspace to `untrusted` and keeps the
preflight open with the activation error. If that rollback also fails, the
screen says that `trusted` may remain and prints the exact `spice untrust ROOT`
repair command; it never reports an activation failure as a save failure.

A workspace already recorded as trusted or untrusted skips the preflight. Run
`spice trust DIR` or `spice untrust DIR` and restart to change the decision.

## Starting and resuming

| Command | Result |
| --- | --- |
| `spice` | Open the home stage in the current workspace. |
| `spice -p "PROMPT"` | Open the TUI and submit the first turn immediately. |
| `spice --draft "TEXT"` | Open with `TEXT` in the composer without submitting it. |
| `spice resume` | Open the home stage with the newest local session ready to resume. |
| `spice resume --last` | Resume the newest session directly. |
| `spice resume SESSION` | Resume one session by id. |
| `spice review [BASE]` | Open the worktree review screen directly. |

The home stage shows the effective model, workspace health, account state,
sandbox posture, activation state, and recent work. A concise warning replaces
repository-controlled details while restricted. Type a prompt to start a new
session. With an empty composer, `enter` resumes the newest session when one is
available; `/sessions` opens the session browser.

`--mode build|plan|review`, `--sandbox MODE`, and `--cwd DIR` override the
corresponding startup choices. A resumed transcript is rebuilt from durable
session facts; live and replayed turns use the same rendering path.

Repository activation does not make Plan or Review execute project tooling.
Build owns configured Dune/Merlin producers; switching away from Build stops
the live project watcher before installing the read-only runner.

## Composer and transcript

`enter` submits the composer. `shift+enter` inserts a newline. While a turn is
running, another submission is queued rather than interleaved with the active
turn; an empty-composer `up` recalls the newest queued prompt for editing. A
queued correction is sent after either a successful turn or an interruption,
but is discarded visibly if the turn fails.

The composer recognizes three prefixes:

- `/` opens and filters the command palette;
- `@` completes workspace paths and agent threads;
- `!` enters shell mode and runs the submitted command through the same
  permission and sandbox posture as agent shell commands.

`ctrl+o` expands or collapses verbose reasoning detail. `pageup` and
`pagedown` scroll the transcript; it stays pinned to new output only while it
is already at the bottom.

`esc` dismisses the nearest transient surface first. During a running turn,
pressing it twice interrupts the turn. `ctrl+c` is reserved for quitting and
requires a second press, so an accidental chord does not discard the session.

## Modes and commands

Build mode is the normal coding workflow. Plan mode asks the agent to propose a
plan and park for approval before implementation. `/plan` and `/build` switch
the mode used by the next turn; the composer frame shows a non-default mode.

The review screen is different from Review turn mode: `/review [BASE]` opens a
worktree UI, while `--mode review` changes the model workflow for a turn.

The palette is the current command catalog. Its main groups are:

- session lifecycle: `/clear`, `/fork`, `/compact`, `/rename`, `/sessions`;
- model and account: `/model`, `/login`, `/logout`;
- inspection: `/settings`, `/config`, `/status`, `/usage`, `/skills`;
- display: `/thinking`, `/verbose`;
- workflow: `/plan`, `/build`, `/review`;
- process: `/quit`.

`/skills` shows the discovered inventory. See
[Instructions and skills](instructions-and-skills.md) for project and global
instructions, skill roots, precedence, and per-run controls.

Commands that replace or mutate the active session—such as `/clear`, `/fork`,
and `/compact`—are available only when the current turn is idle. Surface and
display commands remain available while a turn runs.

## Decisions during a turn

A tool call, plan, or question can park the turn and temporarily replace the
composer with a decision surface. The decision is a session fact: the turn
continues after the answer, and a saved blocked session can be resumed without
losing the pending request.

Permission dialogs distinguish a one-time answer from an exact conversation
grant. Review behavior is selected explicitly when the run starts; workflow
mode independently limits writes and commands. Permission is separate from
command confinement: see
[Security](security.md) for the effective policy and sandbox behavior, and
[Permission rules](permission-rules.md) for durable matcher configuration.

## Reviewing the worktree

Open the review screen inside chat with `/review` or directly with:

```sh
spice review          # HEAD..worktree
spice review main     # main..worktree
```

The normal layout keeps the changed-file navigation and selected unified diff
side by side. Below 80 columns it shows one focused pane; `tab` switches panes.
Closing an in-chat review returns to the unchanged chat, while closing a direct
`spice review` run exits the process.

The core review loop is:

- move through files and hunks with the navigation keys shown in the footer;
- press `space` to mark the current scope reviewed and advance;
- press `a` to toggle the whole-feature verdict between pending and approved;
- use `c`/`e` to add or edit a source-backed CR and `x`/`d` to resolve or
  remove one;
- press `t` to close the screen and ask Spice to review the changes as an
  agent turn;
- press `?` for the complete review key table.

Marks and verdicts persist in the global data home's workspace state. They are
tied to content:
surviving marks carry across a refresh, changed scopes become stale or
unreviewed, and an approval for older content is shown as stale rather than
silently remaining fresh. The screen watches the worktree while it is open and
reports refreshes without discarding the current orientation or CR draft.

## Sessions and exit

Sessions are saved as turns progress; there is no separate save command.
`/clear` starts a fresh session without deleting the old one, and `/fork`
continues from the current history in a child session. `/sessions` is the
interactive browser; the complete storage and lifecycle commands are in
[Sessions](sessions.md).

On exit, Spice restores the normal terminal before printing its farewell. When
a session exists, the farewell includes the exact `spice resume SESSION`
command.
