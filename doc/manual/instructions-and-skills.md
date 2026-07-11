# Instructions and skills

Spice has two model-guidance surfaces:

- **instructions** are workspace context included automatically;
- **skills** are named guidance discovered into a catalog and loaded on demand.

Both can shape model behavior, but neither grants tools, permissions, sandbox
access, or a turn mode. Those capabilities remain separate host decisions.

## Instruction files

Global instructions live at `AGENTS.md` in the Spice config home:

```text
$SPICE_CONFIG_HOME/AGENTS.md
```

Without that override, use `$XDG_CONFIG_HOME/spice/AGENTS.md` or
`~/.config/spice/AGENTS.md`.

Project instructions are discovered from the workspace root down to the run
directory. Each directory contributes at most one file, in this precedence:

1. `AGENTS.override.md`
2. `AGENTS.md`
3. `CLAUDE.md`, when compatibility is enabled

The workspace root is the nearest ancestor containing `.git`; without one,
Spice considers only the run directory. A nested `AGENTS.md` below that
directory is not activated until a run starts from within its subtree.

Project instruction discovery runs only in a trusted workspace. While trust is
unknown or explicitly untrusted, Spice does not stat, walk, or read project
instruction candidates; global instructions remain available. The TUI asks
before activating an unknown workspace, while headless runs continue with
project guidance disabled.

Global instructions are not charged against the project budget. Active project
files share `instructions.project_max_bytes` (default `32768` bytes), consumed
from root toward the run directory. When the budget runs out, later content is
truncated or skipped with a visible warning rather than silently changing the
source order.

Instruction candidates must remain inside the workspace after following a file
symlink. Empty, unreadable, outside-workspace, and over-budget candidates are
reported as source facts; they do not turn discovery into a generic startup
error.

## Inspecting model-visible context

Use the debug commands to understand exactly what a run will send without
making a model request:

```sh
spice debug context
spice debug context --json
spice debug prompt --mode build
```

`debug context` reports every discovered source, its active, shadowed,
disabled, skipped, or not-activated state, and budget facts. `debug prompt`
prints the exact model-visible context after workspace facts and mode guidance
are assembled.

Instruction snapshots are not persisted. A new run or debug invocation reads
the files again; an existing workspace runtime keeps the snapshot it started
with.

## Instruction controls

| Config key | Meaning |
| --- | --- |
| `instructions.global` | Load the config-home `AGENTS.md`. |
| `instructions.project` | Load project instruction files. |
| `instructions.claude_md` | Admit `CLAUDE.md` as the lowest-precedence candidate in a directory. |
| `instructions.project_max_bytes` | Positive byte budget shared by active project instructions. |

For one headless invocation:

- `--no-instructions` disables global and project instructions;
- `--no-project-instructions` disables only project instructions;
- `--project-instructions` force-enables project instructions over config, but
  cannot override workspace trust.

These flags are accepted by `spice run` and the relevant `spice debug`
commands.

## Skill layout

A filesystem skill is an immediate child directory containing `SKILL.md`:

```text
.spice/skills/release-check/
├── SKILL.md
└── checklist.md
```

`SKILL.md` uses YAML frontmatter followed by the guidance body:

```markdown
---
name: Release Check
description: Verify a release candidate before publishing.
---

Read checklist.md, inspect the package metadata, and report every blocker.
```

The directory name is the skill identity. It must contain only lowercase
letters, digits, and hyphens, start with a letter or digit, and be at most 64
bytes. `description` is required, single-line, and at most 1024 bytes. `name`
is an optional single-line display name; it does not change the identity.

Other frontmatter keys are ignored with a warning. Sibling regular files are
resources: `skills show` lists them, and the model-visible skill tool can read
them after loading the skill. Built-in skills have no sibling resources.

## Discovery and precedence

In a trusted workspace, skill roots are searched in this order:

1. `.spice/skills` in the workspace;
2. `.agents/skills` in the workspace;
3. `.claude/skills` in the workspace;
4. `skills` in the Spice config home;
5. each configured `skills.paths` entry, in order;
6. skills compiled into Spice.

A relative `skills.paths` entry resolves against the run directory. The first
active candidate for a name wins. Invalid or disabled candidates do not shadow
a valid lower-precedence candidate; `spice skills list` reports every candidate
and the winning origin.

Unknown and untrusted workspaces are not scanned for the first three project
roots. A user-configured `skills.paths` entry is also disabled when its resolved
path lies inside the canonical project root, including relative entries; an
absolute user skill root outside the project remains active. This prevents a
repository from turning a user-owned search setting into ambient project
guidance.

## Activation and context cost

At request assembly, Spice gives the model a budgeted catalog of active skill
names and descriptions. The model can then call the read-only `skill` tool to
load one skill's frontmatter-stripped body and resources. Discovering a skill
does not put its full guidance into every request.

`--skill NAME` is the explicit alternative for a headless start: it injects the
named active skill ahead of the prompt and fails before the model call when the
name is unknown, inactive, or invalid. Repeat the flag to inject multiple
skills in order. It cannot force a trust-disabled project skill. `--no-skills`
removes both discovery and the skill tool for that invocation.

`skills.catalog_max_bytes` (default `8192`) bounds the always-present catalog,
not skill bodies. When necessary, non-builtin descriptions are visibly trimmed;
names remain. `spice skills list` reports catalog bytes and an approximate token
cost, while each skill reports the estimated cost of loading its body.

## Skill controls and inspection

| Config key | Meaning |
| --- | --- |
| `skills.enabled` | Enable the whole skill surface. |
| `skills.builtin` | Include compiled-in skills. |
| `skills.project` | Include `.spice/skills`. |
| `skills.compat` | Include `.agents/skills` and `.claude/skills`. |
| `skills.disabled` | JSON array of skill names excluded from every root. |
| `skills.paths` | JSON array of additional root paths. |
| `skills.catalog_max_bytes` | Positive byte budget for catalog text. |

Inspect discovery before running a model:

```sh
spice skills list
spice skills list --json
spice skills show release-check
```

`skills list` distinguishes active, shadowed, disabled, and invalid candidates
and prints warnings for ignored frontmatter or catalog trimming. `skills show`
accepts only an active skill and prints its provenance, raw `SKILL.md`, digest,
and resources. In the TUI, `/skills` opens the same discovered inventory.
