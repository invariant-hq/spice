# Security

Spice keeps three policy questions separate: whether ambient project
customization may activate, whether a described operation is approved, and
what operating-system authority the operation receives. They reinforce one
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
| Workspace trust | Whether ambient project configuration, instructions, skills, notices, and built-in tooling may activate. | It does not approve tools or grant file, command, or network authority. |
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

### Reviews and session grants

The interactive permission dialog offers:

- allow once;
- allow this exact access for the session;
- deny, optionally with model-visible feedback.

An allow-once answer authorizes only the blocked operation. An allow-session
answer reconstructs an exact grant from the durable permission request when the
session is replayed. It does not broaden a file to its directory, a command to
its prefix, or a host to all network traffic. A tool may mark a sensitive
request non-grantable, in which case the session choice is intentionally capped
at one use.

Headless runs use the same durable permission facts. With the default
`permission.unattended=block`, a required review saves the session, exits with
code 3, and prints commands such as:

```sh
spice run reply SESSION --allow PERMISSION_ID
spice run reply SESSION --allow-session PERMISSION_ID
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
| `read-only` | Reads are allowed across the host filesystem; writes and network are denied. Native mutation and auxiliary execution tools are omitted from the catalog; `shell` remains and is confined. Shell escalation is unavailable. |
| `workspace-write` | Reads are allowed across the host filesystem. Writes are allowed only under resolved writable roots, with protected carve-outs. Network is restricted by default. |
| `danger-full-access` | Commands run without Spice confinement. The child inherits the unfiltered process environment. |
| `external-sandbox` | Spice records that an external boundary owns confinement. Commands are not wrapped and the environment is not filtered by Spice. |

The mode precedence is the `--sandbox` flag, then `sandbox.mode`, then the
built-in `workspace-write` default.

**The confined modes are not confidentiality boundaries.** They deliberately
allow reads of the whole host filesystem so developer toolchains remain
available. A confined shell command can read files outside the workspace if
ordinary filesystem permissions allow it. Environment filtering removes many
ambient credentials, and restricted network reduces command-side exfiltration,
but neither prevents a command from returning readable file contents in its
tool output. Use an external isolation boundary when host-file confidentiality
is required. If read-anywhere is deliberate—for example with a local
model—use the ordered opt-in in
[Permission rules](permission-rules.md#prompt-free-confined-shell-for-a-local-model).

Native file tools have a narrower boundary: they accept workspace paths, check
realpath containment when dereferencing them, refuse symlink escapes, and do
not expose arbitrary host-file reads.

### Writable and protected paths

`workspace-write` makes these roots writable:

- every workspace root;
- `/tmp` when present and `$TMPDIR` when valid;
- absolute or `~`-relative paths in `sandbox.writable_roots`;
- the Dune cache for a workspace containing `dune-project`, when
  `sandbox.toolchain_caches=true`.

Existing paths are realpath-canonicalized before the policy is generated, so
the described path and the backend-enforced path agree across symlinks such as
macOS `/tmp`.

The following remain read-only even when nested under a writable root:

- `.git` and `.spice` entries;
- the user config, credential, and trust-store directory;
- the project config directory;
- the session store root;
- the same protected metadata names beneath configured and toolchain-cache
  writable roots.

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

### Environment filtering

Confined commands do not inherit environment variables whose names look like:

- credentials (`*TOKEN*`, `*SECRET*`, API-key forms, and provider prefixes);
- credential-agent handles such as `SSH_AUTH_SOCK` and `GPG_AGENT_INFO`;
- loader injection such as `LD_*` and `DYLD_*`;
- shell-startup overrides such as `BASH_ENV`.

Matching is case-insensitive by variable name. Values are never included in
sandbox diagnostics. `PATH`, `OPAM_SWITCH_PREFIX`, `OCAMLPATH`, and `CAML_*`
toolchain variables are retained so commands can locate the developer
toolchain.

`danger-full-access` and `external-sandbox` pass the environment through
unchanged. An approved per-command escalation drops filesystem and network
confinement but still applies the credential and loader-variable filter.

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
- retains the credential and loader-variable environment filter;
- records `not_requested` sandbox evidence;
- does not broaden to another command, even after an allow-session answer.

Read-only mode refuses escalation without opening a permission review. In
`danger-full-access` and `external-sandbox`, escalation is ignored because the
requested lack of Spice confinement is already the current posture.

## Workspace config and trust

Workspace trust is persistent consent for ambient project customization. The
decision is stored user-side for the canonical project root and has three
states:

- `unknown`: no decision has been stored;
- `untrusted`: the user explicitly chose restricted operation;
- `trusted`: project customization may activate.

Unknown and untrusted workspaces have identical runtime capabilities. Spice
does not open project config, scan project instructions or skills, start
project notices, or run automatic Dune/Merlin/Git discovery. Ordinary source
inspection and user-owned config, instructions, and skills remain available.
Directly reading or editing `.spice/config.json` is also allowed; its values do
not become effective until the workspace is trusted.

In an interactive TUI, an unknown workspace gets a preflight before the normal
app, session creation, or project process startup. Continuing without
customization is selected by default and remembers `untrusted`; trusting
remembers `trusted`; exiting stores nothing. Headless commands never prompt or
infer consent: they continue restricted and explain how to run `spice trust`.
Permission bypass does not bypass workspace trust.

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
