# Configuration

Spice configuration is JSON, resolved from layered sources. `spice config
show --origins` prints the effective configuration and where each value came
from; `spice config path` prints the file locations.

## Files and precedence

Values are resolved in increasing precedence:

1. User config: `~/.config/spice/config.json` (or
   `$XDG_CONFIG_HOME/spice/config.json`).
2. Project config: `.spice/config.json` — shared, checked into the project.
3. Project-local config: `.spice/config.local.json` — personal, gitignored.
4. Extra config file named by the `SPICE_CONFIG` environment variable.
5. `SPICE_*` environment overrides.
6. Runtime overrides, such as run flags (`--model`, `--sandbox`, ...).

Project config and project skills resolve from the nearest ancestor containing
`.git`; the execution cwd remains the exact directory requested by the user.
Initializing either project config file maintains an exact
`config.local.json` entry in `.spice/.gitignore` while preserving other lines.
Do not ignore the whole `.spice/` directory if shared config or skills are
committed.

Storage roots are independent of these config layers and cannot be redirected
by project files:

- `SPICE_CONFIG_HOME`: user-authored config plus auth and trust stores;
- `SPICE_DATA_HOME`: durable sessions, workflow artifacts, and workspace state;
- `SPICE_STATE_HOME`: machine-local prompt history, logs, and crash reports.

On Unix, data and state fall back through `XDG_DATA_HOME`/`XDG_STATE_HOME` to
`~/.local/share/spice`/`~/.local/state/spice`.

Project layers activate only when the canonical project root is trusted. In an
unknown or explicitly untrusted workspace, Spice does not open either file and
`spice config show --origins` reports that project configuration is disabled.
Once trusted, the files are still reduced to a narrow allowlist: permission
rules and authority-bearing keys are ignored, and budget values may tighten but
not widen values selected outside the workspace. See
[Security](security.md#workspace-config-and-trust) for the complete boundary.

## Commands

```sh
spice config path                 # print config file locations
spice config show [--json] [--origins]
spice config validate [--strict] [PATH]
spice config get KEY
spice config set KEY VALUE [--project | --project-local]
spice config unset KEY [--project | --project-local]
spice config init                 # scaffold a config file
```

Editing commands write the user config by default; `--project` targets
`.spice/config.json` and `--project-local` targets `.spice/config.local.json`.
These explicit file operations remain available before trust, but the values
activate only after `spice trust` records the workspace root.

## Keys

Keys supported by `get`, `set`, and `unset`:

| Key | Meaning |
| --- | --- |
| `model` | Main model selector, e.g. `openai/gpt-5`. |
| `small_model` | Small-model selector used for cheaper helper tasks. |
| `reasoning` | Default reasoning effort: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. |
| `tui.thinking` | Whether the TUI shows thinking summaries. |
| `providers.ID.base_url` | API root override for provider `ID`. |
| `run.max_steps` | Maximum model/tool cycles per run. |
| `permission.mode` | Durable permission preset: `default`, `accept-edits`, or `plan`. `bypass` is available only through the per-run `--permission-mode` flag. |
| `permission.unattended` | Headless review policy: `block` (default) or `deny`. |
| `sandbox.mode` | Command sandbox: `read-only`, `workspace-write`, `danger-full-access`, or `external-sandbox`. |
| `sandbox.require` | Enforcement gate: `enforced` (default), `enforced-or-external`, or `off`. |
| `sandbox.writable_roots` | Additional absolute or `~`-relative writable roots for `workspace-write`. |
| `sandbox.network` | Confined shell-command network posture: `restricted` (default) or `enabled`. |
| `sandbox.toolchain_caches` | Add curated toolchain caches to `workspace-write` roots. |
| `shell` | Shell program used for shell commands. |
| `workspace.tooling` | Whether the OCaml/Dune workspace tooling runs: `auto` (default), `on`, or `off`. |
| `instructions.global` | Load the global `AGENTS.md` from the config home. |
| `instructions.project` | Load project instruction files. |
| `instructions.claude_md` | Load `CLAUDE.md` compatibility files. |
| `instructions.project_max_bytes` | Byte budget for project instruction text. |

The full configuration surface is larger; `spice config show --json` prints
all of it. Additional groups accepted by `get`, `set`, and `unset` include:

- `notices.*` — host notice producers: `fswatch`, `cr_comments`,
  `dune_diagnostics`, `dune_build`.
- `skills.*` — skill discovery: `enabled`, `builtin`, `project`, `compat`,
  `paths`, `catalog_max_bytes`.
- `tools.anchored_edits` — enable the anchored line-edit tool.
- `web.*` — web tools: `enabled`, `allow_private_network`, `search_backend`,
  `fetch_max_bytes`, `output_max_chars`, `timeout_ms`, `max_timeout_ms`.

See [Instructions and skills](instructions-and-skills.md) for instruction-file
precedence, skill authoring and discovery, context budgets, and per-run
overrides.

`permission.rules` is the structured exception: edit it directly in user or
extra config, inspect it with `spice permission list`, and remove individual
writable rules with `spice permission remove`. See
[Permission rules](permission-rules.md) for the matcher JSON, source behavior,
and evaluation order.

## Workspace tooling

In a trusted workspace, `workspace.tooling` gates Spice's OCaml/Dune
integration for a session: the boot-time `dune describe` project-shape capture,
the `dune build --watch` instance behind the footer's `dune:` build-health glyph
and the Dune diagnostics notices, the filesystem watcher, and Merlin program
resolution.

| Value | Behavior |
| --- | --- |
| `auto` | Default. Engage the tooling only when the working directory holds a `dune-project` or `dune-workspace` file. |
| `on` | Always engage the tooling. |
| `off` | Never engage it. |

Unknown and untrusted workspaces behave as if the integration did not engage,
regardless of the configured value. When the tooling does not engage, Spice
starts no background workspace processes and the footer's `dune:` glyph shows
the degraded state; the OCaml and Dune tools stay in the catalog and can still
run on demand through ordinary permission and sandbox checks. `off` is the
setting for trusted CI, headless, and non-interactive runs that want a
deterministic, process-free session. The `SPICE_WORKSPACE_TOOLING` environment
variable overrides the configured value with the same `auto`, `on`, and `off`
spellings; it cannot override workspace trust.

Trust does not override run mode. A trusted read-only run may perform
read-only Dune/Merlin inspection through the sealed sandbox, but never starts
the mutating `dune build --watch` producer.

## OCaml toolchain resolution

The OCaml tools — the `dune describe` project capture, the `dune build
--watch` instance, Merlin, and the eval tool — spawn `dune` (and friends)
from the environment Spice inherited at launch. Spice never runs
`opam env` itself; it resolves each program by walking a fixed ladder,
first match wins:

1. **`SPICE_DUNE`** — an explicit executable override (generally
   `SPICE_<PROGRAM>`: the program name uppercased, with non-alphanumeric
   runs as `_`, so Merlin's is `SPICE_OCAMLMERLIN`). An override that is
   set but not an executable file fails the resolution outright; it never
   falls through to the rungs below.
2. **`PATH`** — the inherited search path. This is the normal case: launch
   Spice from a shell where `command -v dune` prints a real path and
   nothing else engages.
3. **`$OPAM_SWITCH_PREFIX/bin`** — the variable `eval $(opam env)` exports
   for the active switch. This recovers sessions launched from a context
   that had the switch active but lost `PATH` (editor terminals, desktop
   launchers).
4. **`<workspace root>/_opam/bin`** — an opam local switch at the
   workspace root.

If your shell shows `dune` but Spice reports it missing, the usual cause is
that the shell exposes it only through an alias or an interactive-only hook
that child processes do not inherit. Relaunch from a shell where
`command -v dune` prints a real path, or set `SPICE_DUNE`.

Two surfaces show the resolution without starting a session: `spice doctor`
carries an `ocaml toolchain` check, and `spice sandbox explain` a
`toolchain=` line. Both print where `dune` resolves from — or, when it does
not, every rung that was checked. The sandbox is never the cause of a
missing toolchain: the confined mount keeps the whole host filesystem
readable (`readable=/` in `spice sandbox explain`); only writes are scoped.

## Filesystem Notices

`notices.fswatch=true` publishes "Workspace files changed" notices while a run
is active. The notice is a snapshot-diff summary since the previous watcher
scan, with a bounded preview of changed workspace-relative paths.

The filesystem watcher ignores any path with a `.git`, `_build`, `_opam`, or
`.spice` path segment. Ignored directories are not scanned and do not appear in
filesystem notice batches.

`notices.fswatch=false` suppresses file-change notices, but the shared
filesystem watcher may still run when `notices.cr_comments=true`; the CR
comment observer uses the same watcher batches. Watcher startup and runtime
failures degrade to warning notices when filesystem notices are enabled instead
of failing the run.

## Providers and models

Configuration selects models and provider base URLs, but authentication,
credential precedence, readiness checks, local model downloads, and compatible
server setup are separate workflows. See
[Providers and accounts](providers.md) for the complete path.

Permissions, sandboxing, workspace config, and trust compose as described in
the [security guide](security.md).
