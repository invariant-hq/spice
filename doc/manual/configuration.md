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

Project layers apply only after the workspace is trusted with `spice trust`
(revoked with `spice untrust`). Until then, project configuration is ignored.

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
| `permission.mode` | Permission preset: `default`, `accept-edits`, `plan`, or `bypass`. |
| `shell` | Shell program used for shell commands. |
| `workspace.tooling` | Whether the OCaml/Dune workspace tooling runs: `auto` (default), `on`, or `off`. |
| `instructions.global` | Load the global `AGENTS.md` from the config home. |
| `instructions.project` | Load project instruction files. |
| `instructions.claude_md` | Load `CLAUDE.md` compatibility files. |
| `instructions.project_max_bytes` | Byte budget for project instruction text. |

The full configuration surface is larger; `spice config show --json` prints
all of it. Groups not yet reachable through `set` are edited directly in the
config files:

- `notices.*` — host notice producers: `fswatch`, `cr_comments`,
  `dune_diagnostics`, `dune_build`.
- `skills.*` — skill discovery: `enabled`, `builtin`, `project`, `compat`,
  `paths`, `catalog_max_bytes`.
- `tools.anchored_edits` — enable the anchored line-edit tool.
- `web.*` — web tools: `enabled`, `allow_private_network`, `search_backend`,
  `fetch_max_bytes`, `output_max_chars`, `timeout_ms`, `max_timeout_ms`.
- `sandbox.*` — sandbox mode and enforcement requirements.

## Workspace tooling

`workspace.tooling` gates Spice's OCaml/Dune integration for a session: the
boot-time `dune describe` project-shape capture, the `dune build --watch`
instance behind the footer's `dune:` build-health glyph and the Dune
diagnostics notices, the filesystem watcher, and Merlin program resolution.

| Value | Behavior |
| --- | --- |
| `auto` | Default. Engage the tooling only when the working directory holds a `dune-project` or `dune-workspace` file. |
| `on` | Always engage the tooling. |
| `off` | Never engage it. |

When the tooling does not engage, Spice starts no background workspace
processes and the footer's `dune:` glyph shows the degraded state; the OCaml and
Dune tools stay in the catalog and fall back to their on-demand behavior. `off`
is the setting for CI, headless, and non-interactive runs that want a
deterministic, process-free session. The `SPICE_WORKSPACE_TOOLING` environment
variable overrides the configured value with the same `auto`, `on`, and `off`
spellings.

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

## Models

`spice models` lists the model catalog. Related commands:

```sh
spice models show MODEL           # metadata: context window, reasoning support
spice models current              # effective main/small models
spice models select MODEL [--small] [--project | --project-local]
```

Provider credentials are managed separately by `spice auth`; see
`spice auth --help`. Credentials resolve from provider environment variables
first, then the auth store at `~/.config/spice/auth.json`.

## OpenAI-compatible servers (llama.cpp, vLLM, LM Studio, Ollama)

The `ollama` provider is Spice's client for the OpenAI **chat-completions**
wire protocol (`POST /v1/chat/completions`). That protocol is what Ollama's
`/v1` endpoint speaks, and it is also what self-hosted servers such as
llama.cpp (`llama-server`), vLLM, and LM Studio expose. Point the provider at
any of them and it works the same way.

Two facts make this the right provider for a custom server:

- The daemon owns the model set. Spice declares no built-in Ollama models, so
  **any** model id you configure resolves — no catalog entry required. Put the
  exact id the server serves in `model`, prefixed with `ollama/`.
- Authentication is optional. A bare local daemon needs none; a key-protected
  deployment takes an API key that Spice sends as a bearer authorization header.

Do **not** point `providers.openai.base_url` at such a server. The `openai`
provider speaks the OpenAI **Responses** API (`POST /v1/responses`), which
llama.cpp and friends do not implement, and its model id is validated against
the built-in OpenAI catalog. Use the `ollama` provider instead.

Configure the base URL as the server **root** (the provider appends
`/v1/chat/completions`):

```sh
spice config set providers.ollama.base_url http://your-server:8080
spice config set model ollama/your-model-id
```

or per shell, without writing to config:

```sh
export SPICE_OLLAMA_BASE_URL=http://your-server:8080
export SPICE_MODEL=ollama/your-model-id
```

For a key-protected server, supply the key with either the environment
variable

```sh
export OLLAMA_API_KEY=your-key
```

or the auth store:

```sh
spice auth login ollama --api-key-stdin   # reads the key from stdin
```

The stored form writes `~/.config/spice/auth.json`:

```json
{"version":1,"credentials":{"ollama":{"default":{"kind":"api_key","api_key":"your-key"}}}}
```

Model discovery is not implemented: Spice does not call the server's
`GET /v1/models`, so the model id is always taken from configuration.
