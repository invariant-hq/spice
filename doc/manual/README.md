# Spice manual

User-facing documentation for the `spice` binary. For design documents and
internal notes, see the rest of [`doc/`](../).

- [Configuration](configuration.md) — config files, precedence, workspace
  filtering, and the `spice config` commands.
- [Security](security.md) — permissions, command sandboxing, workspace trust,
  escalation, and audit surfaces.
- [Permission rules](permission-rules.md) — durable rule precedence, matcher
  JSON, authoring, inspection, and removal.
- [Sessions](sessions.md) — where sessions live and how to list, resume,
  fork, diff, and revert them.
- [Headless runs](headless.md) — `spice run` for scripts
  and CI: run flags, the JSONL event stream, exit codes, and the
  blocked-session resume contract.
- [Shell completions](completions.md) — installing cmdliner completion
  for zsh, bash, and PowerShell.
