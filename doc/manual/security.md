# Security

Spice keeps three policy questions separate: whether repository-controlled
inputs and processes may activate, whether a described operation is approved,
and what operating-system authority the operation receives. They reinforce one
another, but none substitutes for another.

The default posture is:

- permission preset `default`;
- unattended permission policy `block`;
- sandbox mode `workspace-write`;
- sandbox requirement `enforced`;
- command network access `restricted`;
- curated toolchain cache writes enabled.

On a supported host, and absent an earlier durable rule, this lets ordinary
native workspace edits run without review because their filesystem capability
is bounded. Model-authored shell commands still require review: write
confinement does not authorize the host files they can read. Fixed host tools
remain low-friction because their sealed child processes implement the typed
operation the user approved; they are not exposed as additional shell
authority. If the platform cannot enforce the default sandbox, the run fails
before provider credentials are loaded or a session is created.

## The three boundaries

| Boundary | What it decides | What it does not do |
| --- | --- | --- |
| Repository activation | Whether repository configuration, instructions, skills, executable tools, and project processes may activate. | It does not approve an operation or widen the selected sandbox. |
| Permission policy | Whether a host-described operation is allowed, denied, or requires review. | It does not confine a process or grant an OS capability. |
| Runtime confinement | What an approved native tool or spawned process may access. | It does not approve the operation or activate project inputs. |

Runtime confinement has two implementations. Native file tools resolve typed
workspace paths, check realpath containment, and protect metadata. Standard
command-bearing tools and trusted automatic Dune/Merlin/Git integrations spawn
through the sealed command sandbox. Explicit frontend operations such as a
login browser remain outside the model-tool boundary. Provider calls and web
tools use their own host APIs; `sandbox.network` is not a process-wide firewall
and does not disable those services.

## Permission policy

Tools construct trusted access facts from already decoded input before they run
an operation. The built-in facts describe workspace path reads and writes,
commands, network targets, and tool-specific custom operations. Display text
and proposed diffs are review evidence; they do not change permission identity.

Policy evaluation is pure and ordered:

1. Plan's command-deny guard applies first when that preset is selected.
2. Session-scoped family allows installed by a reviewer apply next.
3. Durable rules are evaluated in order.
4. The selected preset's ordinary rules follow the durable rules.
5. Native-mutation rules credited from an enforcing workspace-write sandbox
   follow the preset.
6. For each access, the first matching rule wins.
7. If no rule matches, an exact session grant may allow the access.
8. Otherwise the access requires review.

Rules take precedence over session grants. A later deny or review rule can
therefore override an earlier session approval. In a grouped request, any
denied access denies the request; otherwise only the unmatched or explicitly
reviewed accesses are presented for review.

The shell tool parses simple commands into structured argv facts when it can
and falls back to the original shell text when parsing is ambiguous. This
improves rule matching and review display, but it is not a security parser:
confinement does not depend on the parse succeeding.

### Permission presets

| Preset | Base behavior | Additional behavior under an enforcing `workspace-write` sandbox |
| --- | --- | --- |
| `default` | Allows workspace reads. Other accesses require review. | Also allows native workspace creates, modifications, and deletions. Shell commands remain reviewable. |
| `accept-edits` | Allows workspace reads, creates, modifications, and deletions. Commands and other accesses require review. | No command allowance is added. |
| `plan` | Allows workspace reads and denies workspace writes and commands. | No additional rules; the deny posture is preserved. |
| `bypass` | Allows every access not decided by an earlier durable rule. | No additional rules are needed. |

The destructive-command matcher deliberately errs toward review. It recognizes
destructive file, Git, and disk operations; recursively unwraps standard
shells, `command`, `exec`, and common pass-through wrappers; and treats
substitutions, redirects, dynamic evaluation, and other opaque shell syntax
conservatively. It may therefore review a harmless expression. A non-match is
not authority and is not a proof that a command is harmless.

`bypass` is intentionally per-run only:

```sh
spice run --permission-mode bypass "PROMPT"
```

Config files and `SPICE_PERMISSION_MODE` reject `bypass`. Explicit durable
deny or review rules still precede the bypass preset and still apply.

### Reviews and conversation grants

The interactive permission dialog offers:

- allow once;
- allow this exact access for the conversation;
- deny, optionally with model-visible feedback.

An allow-once answer authorizes only the blocked operation. An exact-conversation
answer reconstructs an exact grant from the durable permission request whenever
the conversation is replayed. It does not broaden a file to its directory, a
command to its prefix, or a host to all network traffic. Explicit review and
deny rules still take precedence over exact grants.

Family approvals are durable protocol values, but the interactive dialog does
not guess or offer them. A future family editor must show the complete matcher
before saving it; until then, configure family rules explicitly.

Headless runs use the same durable permission facts. With the default
`permission.unattended=block`, a required review saves the session, exits with
code 3, and prints commands such as:

```sh
spice run reply SESSION --allow PERMISSION_ID
spice run reply SESSION --allow-conversation PERMISSION_ID
spice run reply SESSION --deny PERMISSION_ID
spice run reply SESSION --deny PERMISSION_ID --message TEXT
```

With `permission.unattended=deny`, a required review is automatically denied,
the denial is recorded with `unattended` provenance, and the run continues so
the model can respond. Unattended resolution never allows an operation, creates
a session grant, or writes a policy rule.

### Durable rules

Durable rules are structured JSON under `permission.rules`. They may come from
the user config or the explicitly selected extra config file. The extra file's
rules have higher precedence than user rules. Project and project-local rules
are always stripped, and environment variables and run flags cannot carry
rules. The complete JSON matcher reference and authoring workflow are in
[Permission rules](permission-rules.md).

Rules are currently hand-authored; `spice config set` does not edit the
structured rule list. For example:

```json
{
  "permission": {
    "rules": [
      {
        "action": "deny",
        "matcher": {
          "type": "path-exact-relative",
          "relative": ".env"
        }
      },
      {
        "action": "allow",
        "matcher": {
          "type": "command",
          "pattern": {
            "type": "argv-prefix",
            "execution": "enforced",
            "cwd": { "type": "workspace" },
            "program": "dune",
            "args": ["build"]
          }
        }
      }
    ]
  }
}
```

Relative path matchers are portable across workspace roots. Exact workspace
matchers include the workspace root identity. Command matchers can match an
exact structured command, an argv prefix, or every command. Network matchers
use the normalized protocol, host, and explicit port supplied by the host; they
do not resolve DNS aliases or infer default ports.

Inspect the static rule table with:

```sh
spice permission list
spice permission list --json
spice permission remove RULE_ID
```

Rule ids are derived from rule content, not list position. `permission list`
shows durable rules followed by the selected preset. Sandbox-backed runtime
rules are derived while a run is planned and are instead visible through the
run's permission provenance. `permission remove` edits writable user config;
rules from an explicitly supplied extra config must be removed from that file
directly.

## Command sandbox

The sandbox applies to the `shell` tool, fixed-command search helpers, OCaml
tools that spawn Dune, Merlin, ocamlfind, or a toplevel, and automatic trusted
project integrations. The host resolves one posture, gates it before credential
or session effects, seals it against a platform backend, and hands command
executors the sealed spawn capability. Shell results additionally carry
evidence saying whether confinement was enforced, refused, not requested, or
declared external.

The spawn plan also owns the canonical working directory. Confined cwd must be
inside the resolved readable roots; Bubblewrap enters it after mounting the
policy, and direct process runners fork into that same directory. An invalid,
missing, or out-of-scope cwd refuses before a child starts.

Shell command facts distinguish Spice-enforced, externally confined, and direct
execution routes. Sandbox refusal produces no route, no permission prompt, and
no child. The default and accept-edits presets review every executable route;
users who accept read-anywhere confined execution may explicitly allow the
enforced route with ordered durable rules. Fixed host tools do not expose their
implementation argv as command facts. Model-authored evaluator source is itself
a command fact, with its language, source, cwd, and route in exact permission
identity. Shell escalation is a `direct` command fact plus a separate custom
access, so an enforced command grant cannot be reused to approve dropping
confinement.

### Modes

| Mode | Command behavior |
| --- | --- |
| `read-only` | Reads follow `sandbox.read`; writes are limited to a private run scratch directory and network is denied. Native mutation and auxiliary execution tools are omitted from the catalog; an activated repository retains confined `shell`. Shell escalation is unavailable. |
| `workspace-write` | Reads follow `sandbox.read`. Writes are allowed only under resolved writable roots, with protected carve-outs. Network is restricted by default. |
| `danger-full-access` | Commands run without Spice filesystem or network confinement. They still receive the exact host-constructed child environment. |
| `external-sandbox` | Spice records that an external boundary owns confinement. Commands are not wrapped, but still receive the exact host-constructed child environment. |

The mode precedence is the `--sandbox` flag, then `sandbox.mode`, then the
built-in `workspace-write` default.

### Filesystem read scope

`sandbox.read` selects what confined commands may read:

| Value | Read behavior |
| --- | --- |
| `all` | Default. Reads may reach the host filesystem wherever ordinary filesystem permissions allow. |
| `project` | Reads are limited to the workspace, `sandbox.readable_roots`, executable search roots, OCaml toolchain roots, and the platform runtime files required to launch commands. |

Configured readable roots must be absolute or `~`-relative. They must already
exist, resolve physically, and may not name the filesystem root or the user's
home directory. The resolver reports an invalid root before the run starts;
there is no silent fallback to broader reads.

Project scope resolves physical roots once and shows their origin in
`spice sandbox explain`. The active OPAM switch is admitted as a whole because
OCaml executables need its libraries, stublibs, findlib metadata, and sibling
tools. A linked Git worktree's `gitdir` and `commondir` are parsed without
executing Git and admitted read-only. Platform runtime roots expose some
machine facts to commands; project scope is a bounded confidentiality boundary,
not a claim that command output contains only repository text.

Broad roots fail closed: `/`, the user's home directory, and an ancestor of the
workspace cannot enter a project-scoped allowlist indirectly through config,
`PATH`, or OCaml toolchain variables. Readable roots may be files or
directories; writable roots must be directories. Requested roots must still
exist when a command starts, or the sandbox reports a stale-policy refusal.

With `sandbox.read=all`, the confined modes are not confidentiality boundaries.
A confined command can read files outside the workspace and return their
contents in tool output. Exact environment reconstruction withholds ambient
credentials, and restricted network reduces command-side exfiltration, but
neither prevents disclosure to the model. Use `sandbox.read=project` or an
external isolation boundary when host-file confidentiality matters. If
read-anywhere is deliberate—for example with a local model—use the ordered
opt-in in [Permission rules](permission-rules.md#prompt-free-confined-shell-for-a-local-model).

Native file tools have a narrower boundary: they accept workspace paths, check
realpath containment when dereferencing them, refuse symlink escapes, and do
not expose arbitrary host-file reads.

### Writable and protected paths

`workspace-write` makes these roots writable:

- every workspace root;
- a private mode-`0700` home and temporary directory owned by the run;
- absolute or `~`-relative paths in `sandbox.writable_roots`.

Existing paths are realpath-canonicalized before the policy is generated, so
the described path and the backend-enforced path agree across symlinks such as
macOS `/tmp`.

The following remain read-only even when nested under a writable root:

- existing workspace `.git` and `.spice` entries;
- linked-worktree Git metadata outside the workspace;
- the user config, credential, and trust-store directories;
- the project config directory;
- the session store root.

Native mutation tools share the `.git` and `.spice` protection. They also
validate workspace containment independently of the command sandbox.

### Network policy

`sandbox.network=restricted` is the default for `read-only` and
`workspace-write`. Linux Bubblewrap creates a separate network namespace;
macOS Seatbelt omits network permission from its profile. Set
`sandbox.network=enabled` or `SPICE_SANDBOX_NETWORK=enabled` to permit network
for confined shell commands.

This setting does not authorize a command under the permission policy and does
not control provider calls or web tools. Web fetching has separate enablement,
private-network checks, URL policy, and permission facts.

### Exact child environments

Every spawned route—confined, direct, externally sandboxed, and approved
escalation—receives one exact environment constructed when the run resolves its
sandbox. Tools cannot add per-call overlays and no route inherits the ambient
process environment.

The child environment contains:

- `PATH`, validated as absolute non-empty entries;
- private run-owned `HOME`, `TMPDIR`, `TMP`, and `TEMP`;
- deterministic non-interactive pager, terminal, and color settings;
- valid locale and OCaml toolchain path variables from a fixed allowlist.

Optional inherited values that are malformed are omitted. Values are never
included in sandbox diagnostics. After repository activation, an existing
canonical workspace-local `_opam/bin` leads `PATH`; a restricted repository
cannot contribute executable roots.

### Enforcement requirements and backends

`sandbox.require` controls the run-start gate:

| Value | Gate behavior |
| --- | --- |
| `enforced` | Default. Confined modes require a working Spice backend; an external declaration is not sufficient. |
| `enforced-or-external` | Accepts either a working Spice backend or `external-sandbox`. |
| `off` | Does not fail the run at startup. A confined mode with no backend still refuses each shell command rather than running it unconfined. |

`--require-sandbox` forces `enforced` for one invocation.

Spice selects `/usr/bin/bwrap` on Linux and `/usr/bin/sandbox-exec` on macOS.
Bubblewrap is unavailable on WSL1 and is probed with a minimal isolated
process before use. Other platforms have no built-in enforcing backend. A
restricted run fails closed when its applicable requirement is not met.

### Per-command escalation

In a `workspace-write` sandbox, the model can request `escalate:true` on one
shell call. The request adds a separate `shell.escalate` access whose subject
is the exact command text. Reaching execution means both the ordinary command
access and the escalation access were allowed by policy or reviewer.

An approved escalation:

- runs that one command without filesystem or network confinement;
- retains the policy's exact child environment;
- records `not_requested` sandbox evidence;
- does not broaden to another command, even after an exact-conversation answer.

Read-only mode refuses escalation without opening a permission review. In
`danger-full-access` and `external-sandbox`, escalation is ignored because the
requested lack of Spice confinement is already the current posture.

## Repository activation and trust

Workspace trust is persistent consent to activate repository-controlled inputs
and processes. The decision is stored user-side for the canonical project root
and has three states:

- `unknown`: no decision has been stored;
- `untrusted`: the user explicitly chose restricted operation;
- `trusted`: repository config, instructions, skills, and project processes may
  activate after reload.

Unknown and untrusted workspaces have identical runtime capabilities. Spice
does not open project config, scan project instructions or skills, offer the
generic shell or evaluator, start project notices, or run automatic
Dune/Merlin/Git discovery. Native source inspection, search, and structural
edits remain available according to workflow, permission, and sandbox policy,
as do user-owned config, instructions, and skills. Directly reading or editing
`.spice/config.json` is also allowed; its values do not become effective until
the workspace is trusted and Spice reloads. Files edited while restricted may
therefore execute after later activation.

In an interactive TUI, an unknown workspace gets a preflight before the normal
app, session creation, or project process startup. Continuing restricted is
selected by default and remembers `untrusted`; trusting activates only after a
clean host reload and remembers `trusted`; exiting stores nothing. The selected
sandbox continues to bound filesystem and network access. Headless commands
never prompt or infer consent: they continue restricted and explain how to run
`spice trust`. Permission bypass does not bypass workspace trust.

Activation makes repository execution eligible; workflow still owns its
lifetime. Build engages configured Dune/Merlin producers when a turn binds.
Plan and Review start none, and switching away from Build stops the current
project watcher, clears its captured project snapshot, and resets Merlin
resolution before the new runner is installed.

Once trusted, project config (`.spice/config.json`) and project-local config
(`.spice/config.local.json`) are reduced to this shared allowlist:

- `model`, `small_model`, and `reasoning`;
- `run.max_steps`;
- `permission.unattended`;
- `workspace.tooling`;
- `tools.editor`;
- `web.search_backend`, `web.fetch_max_bytes`, `web.output_max_chars`,
  `web.timeout_ms`, and `web.max_timeout_ms`.

Trusted automatic Dune, Merlin, notice, and mutation integrations are
product-owned startup behavior, not model tool calls, so they do not create
permission prompts. Their subprocesses still use the run's sealed sandbox and
degrade rather than retrying unsandboxed.

Workspace `run.max_steps` may tighten a value selected outside the workspace
but cannot widen it. Workspace `permission.rules` are always stripped. Every
other supported key outside the allowlist—including permission mode, sandbox
posture, shell program, provider endpoints, web enablement, private-network
access, and user instruction/skill switches—is ignored. Invalid, unreadable, or
oversized workspace config degrades rather than failing host startup. If the
two workspace files create an invalid effective cross-field configuration,
Spice disables both layers together; it never retains an arbitrary half.
`spice config show --origins` reports every ignored, clamped, or degraded
input.

The allowlist still applies after trust. Trust is consent to consume named
project inputs, not a grant of arbitrary authority: permission mode, sandbox
posture, shell and Merlin programs, provider endpoints, web enablement,
private-network access, and instruction/skill switches remain user-owned.
Project prose and skills may influence the model once enabled, but operations
proposed as a result still pass through permission and confinement.

`spice trust DIR` and `spice untrust DIR` record canonical workspace paths in
the user-side `trust.json` store. `DIR` may be a project subdirectory or symlink;
Spice records the real enclosing project root. `untrust` stores an explicit
refusal instead of deleting the entry. Config and state directories use mode
`0700`, and the trust and lock files use mode `0600`.

The trust grant is deliberately narrow. It does not silently enable future
hooks, plugins, MCP servers, credential helpers, environment mutation, or
project-selected executables. Those capabilities require their own explicit,
content-bound approval design.

## Inspection and audit

Use these commands before a run to inspect the effective posture:

```sh
spice config show --origins
spice doctor
spice permission list
spice sandbox status --verbose
spice sandbox explain
```

`config show` reports the effective `workspace_trust` state and omits disabled
project values. `doctor` reports the trust-store path and validity plus the
canonical root and resolved state without contacting a provider or starting
project tooling. Both doctor and sandbox explain omit project-local `_opam`
lookup until the workspace is trusted. `sandbox status` reports platform,
selected backend, mode, requirement, and availability without loading provider
credentials or creating a session.
`sandbox explain` additionally reports readable and writable posture,
protected entries, network state, environment-filter counts, toolchain
resolution, and config origin. Both commands support `--json`.

At run start, text and JSONL output record the effective permission preset and
sandbox posture. Each shell result records its actual enforcement evidence.
Permission requests and replies are durable session events, including whether a
denial came from a reviewer or unattended policy. Inspect them with:

```sh
spice session show SESSION
spice session show --json SESSION
spice session export SESSION
```

Use structured JSON, exit codes, and session events for automation. Human
diagnostic wording is not a stable matching interface.
