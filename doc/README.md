# Spice documentation

The documentation is organized by audience and by source of truth. Start with
the user manual when operating the `spice` binary and with the architecture
overview when changing how the libraries compose.

## User manual

- [Configuration](manual/configuration.md) — config files, precedence,
  workspace-safe project config, and the `spice config` commands.
- [Security](manual/security.md) — permissions, command sandboxing, workspace
  trust, escalation, and the effective default posture.
- [Permission rules](manual/permission-rules.md) — durable policy matcher JSON,
  evaluation order, and safe authoring guidance.
- [Sessions](manual/sessions.md) — storage, lifecycle commands, diffs, and
  reverts.
- [Headless runs](manual/headless.md) — scripting, JSONL events, exit codes,
  and blocked-session continuation.
- [Shell completions](manual/completions.md) — zsh, bash, and PowerShell setup.

## Maintainer documentation

- [Architecture](architecture.md) — cross-library ownership boundaries and the
  main execution, persistence, workspace, and security flows.
- [Error model](dev/error-model.md) — programmer errors, recoverable boundary
  errors, durable workflow facts, fatal faults, and containment seams.
- [Performance](dev/performance.md) — launch, render-loop, and test-suite cost
  models.
- [Deterministic TUI tests](dev/tui-testing.md) — the in-process harness,
  virtual clock, and settling rules.

## Sources of truth

Public OCaml API contracts live in `.mli` files. They define types,
invariants, errors, effects, and the intended composition path for each module.
Markdown does not repeat those item-by-item contracts.

This directory is for material that needs a wider view:

- `manual/` documents user workflows and observable CLI behavior;
- `architecture.md` documents relationships spanning several libraries;
- `dev/` documents contributor procedures and project-wide engineering rules.

Tests are the executable source of truth for exact CLI output and TUI frames.
Temporary plans, investigations, and reviews may exist while work is active,
but they are not living product or API documentation and should be removed or
archived when their decisions have landed.
