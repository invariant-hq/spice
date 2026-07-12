# Permission rules

Durable permission rules are ordered, hand-authored JSON policy. Use them for a
specific exception that the built-in product rules do not express. Read
[Security](security.md) first: a rule decides whether an
operation is allowed, reviewed, or denied, but it does not grant filesystem,
network, sandbox, or operating-system capabilities.

## Storage and precedence

Put rules under `permission.rules` in either:

- the user config, normally `$XDG_CONFIG_HOME/spice/config.json`;
- the extra config selected by `SPICE_CONFIG`.

The extra config's rules evaluate before user rules. Within one file, rules
evaluate in array order. Conversation rules and then fixed product rules follow.
The active workflow contract is a separate outer limit, so an allow installed
for Build cannot leak execution into Plan or Review.

Project `.spice/config.json` and `.spice/config.local.json` files never
contribute permission rules. Spice strips those rules and reports an
`ignored_project_rules` config diagnostic. This prevents repository content
from granting itself authority.

Rules are not available through the scalar `spice config set` interface and the
interactive permission dialog does not create them. Edit the JSON file, then
inspect the result with:

```sh
spice permission list
spice permission list --json
```

`spice permission remove RULE_ID` removes a writable user-config rule by its
content-derived id. Extra config is an explicit input and is not writable
through this command; edit that file directly. Reordering rules does not change
their ids. Duplicate rules within one file and invalid matcher JSON are load
errors.

## Evaluation

Each rule has an action and one matcher:

```json
{
  "action": "deny",
  "matcher": {
    "type": "path-exact-relative",
    "relative": ".env"
  }
}
```

Actions are:

| Action | Effect |
| --- | --- |
| `allow` | Allows a matching access without review. |
| `review` | Requires review even if an exact session grant exists. |
| `deny` | Rejects a matching access without offering review. |

For each access, the first matching rule wins. Rules are checked before exact
session grants. An unmatched, ungranted access requires review. If any access
in a grouped request is denied, the whole request is denied.

This ordering makes broad durable allows powerful. For example, a durable rule
allowing every command suppresses the normal command review in Build.
Prefer the narrowest matcher that describes the intended exception.

## Path matchers

Path matchers accept an optional `op` of `read`, `create`, `modify`, or
`delete`. Omitting `op` matches every path operation in that scope.

Portable relative matchers apply to every workspace root:

```json
{
  "type": "path-exact-relative",
  "op": "read",
  "relative": ".env"
}
```

```json
{
  "type": "path-under-relative",
  "op": "modify",
  "relative": "generated"
}
```

`path-exact-relative` matches one root-relative path.
`path-under-relative` matches that path and its descendants. These forms are
usually preferable because they contain no machine- or checkout-specific root
identity.

Root-specific forms add a workspace root key:

```json
{
  "type": "path-under",
  "root_key": "ROOT_KEY",
  "relative": "lib"
}
```

The tags are `path-exact` and `path-under`. They match only the named workspace
root. Copy a root key from an existing structured access fact rather than
constructing one from a filesystem path.

The broad classified-scope forms are:

```json
{ "type": "path-workspace", "op": "read" }
```

```json
{ "type": "path-outside-workspace", "op": "read" }
```

```json
{ "type": "path-unknown", "op": "read" }
```

An outside-workspace matcher does not make the path writable or readable under
the command sandbox. It changes only the permission decision for a tool that
already has the required runtime capability.

## Command matchers

An argv-prefix rule matches a directly parsed command on one explicit execution
route and working-directory scope, whose program is exact and whose argument
list starts with the supplied arguments:

```json
{
  "type": "command",
  "pattern": {
    "type": "argv-prefix",
    "execution": {
      "kind": "enforced",
      "read": "project",
      "write": "workspace",
      "network": "restricted"
    },
    "cwd": { "type": "workspace" },
    "program": "dune",
    "args": ["build"]
  }
}
```

This matches `dune build`, `dune build @fmt`, and `dune build lib/foo.cmxa`.
It does not match a different program spelling or a command that had to fall
back to an opaque shell-text access because parsing was ambiguous.

Both `execution` and `cwd` are required. A rule cannot silently span direct,
externally confined, and Spice-enforced execution, or every working directory.
Choose a broader scope explicitly when that is the intended policy:

```json
{
  "type": "command",
  "pattern": {
    "type": "argv-prefix",
    "execution": { "kind": "direct" },
    "program": "git",
    "args": ["status"],
    "cwd": { "type": "relative-under", "relative": "." }
  }
}
```

Command working-directory scopes use one of:

- `relative-exact` or `relative-under`, with `relative`;
- `workspace-exact` or `workspace-under`, with `root_key` and `relative`;
- `workspace`, `outside-workspace`, or `unknown`, with no other fields.

The built-in route and broad command patterns are:

```json
{
  "type": "command",
  "pattern": {
    "type": "execution",
    "execution": {
      "kind": "enforced",
      "read": "project",
      "write": "workspace",
      "network": "restricted"
    }
  }
}
```

```json
{ "type": "command", "pattern": { "type": "high_impact" } }
```

```json
{ "type": "command", "pattern": { "type": "any" } }
```

An `enforced` execution identity matches only a host-produced command fact
derived from the exact policy and evidence of the sealed sandbox. Its `read`,
`write`, and `network` members are part of exact permission and grant identity.
`external` identifies a user-selected boundary that Spice cannot verify, and
`direct` identifies no confinement claim. By default, Spice automatically
allows enforced commands only with `project` reads and `restricted` networking,
for either `read-only` or `workspace` writes. It also allows an explicitly
selected external boundary. Read-all, network-enabled, and direct commands stay
reviewable. An escalation request carries a direct ordinary command fact plus
the distinct `shell.escalate` custom access.

`high_impact` recognizes plainly visible bulk or irreversible operations such
as recursive `rm`, forced Git history/worktree operations, direct-device `dd`,
`shred`, and `mkfs`. It recursively inspects standard shell `-c` payloads and
common pass-through wrappers. Opaque code, substitutions, dynamic evaluation,
and parse failures are left to confinement rather than classified as high
impact merely because they are difficult to inspect. A non-match is not proof
of safety. `any` matches every command access and can shadow built-in safety
rules when placed in durable config.

### Prompt-free confined shell for a local model

The read-all confined posture permits reads across the host while restricting
writes. If that is the policy you want—for example, so a local model can inspect
installed `.mli` files—put these rules in the user config, in this order:

```json
{
  "permission": {
    "rules": [
      {
        "action": "review",
        "matcher": {
          "type": "command",
          "pattern": { "type": "high_impact" }
        }
      },
      {
        "action": "allow",
        "matcher": {
          "type": "command",
          "pattern": {
            "type": "execution",
            "execution": {
              "kind": "enforced",
              "read": "all",
              "write": "read-only",
              "network": "restricted"
            }
          }
        }
      },
      {
        "action": "allow",
        "matcher": {
          "type": "command",
          "pattern": {
            "type": "execution",
            "execution": {
              "kind": "enforced",
              "read": "all",
              "write": "workspace",
              "network": "restricted"
            }
          }
        }
      }
    ]
  }
}
```

The first matching rule wins, so the high-impact review must come first. This
allows only execution proven to use Spice's sealed sandbox. It does not allow
direct, externally confined, escalated, refused, or Plan-mode commands. The
tradeoff is explicit: command output can contain any host file readable by the
user account. Use an external VM or container when the model must not see those
files.

An `exact` command pattern wraps a complete command access object. It is mainly
useful for generated policy and is less portable than an argv prefix:

```json
{
  "type": "command",
  "pattern": {
    "type": "exact",
    "access": {
      "type": "command",
      "kind": "argv",
      "program": "git",
      "args": ["status"],
      "execution": { "kind": "direct" },
      "cwd": { "scope": "workspace", "root_key": "/repo", "relative": "." }
    }
  }
}
```

An exact shell access instead uses `"kind": "shell"` and a required `text`
field. Evaluated source uses `"kind":"code"` with required `language` and
`source` fields; source is represented as a command because evaluating it is
arbitrary process execution, even when the implementation argv is fixed. Every
command access requires a `cwd` scope and a tagged `execution` object. An
enforced object also requires `read`, `write`, and `network`; external and
direct objects carry only their `kind`. Execution confinement and working
directory are part of exact permission identity, so a grant for one confinement
cannot be reused by another confinement, a direct operation, or another
workspace.

## Network matchers

A network-host matcher requires an exact host and may restrict protocol and
explicit port:

```json
{
  "type": "network-host",
  "protocol": "https",
  "host": "docs.example.com"
}
```

Built-in protocols are `http`, `https`, `ssh`, `tcp`, and `udp`. A custom
protocol is encoded as `{"type":"other","name":"PROTOCOL"}`. When present,
`port` must be between 1 and 65535.

Host matching is exact. Spice does not case-fold names, resolve aliases,
canonicalize IP literals, or infer default ports. Omitting `protocol` or `port`
means the matcher does not restrict that field; specifying port 443 does not
match an access whose port is absent.

This matcher applies to host-owned network access facts such as web tools. It
does not open the network namespace of a confined shell command; use the
sandbox network setting or an explicitly reviewed escalation for that separate
boundary.

## Generic and custom matchers

Generic matchers are available for advanced policy:

```json
{ "type": "kind", "kind": "network" }
```

`kind` accepts `read`, `write`, `command`, `network`, or `custom`. The matcher
`{"type":"any"}` matches every access. Both are intentionally broad.

An `exact` matcher wraps one complete access fact:

```json
{
  "type": "exact",
  "access": {
    "type": "network",
    "protocol": "https",
    "host": "docs.example.com"
  }
}
```

Access objects have these forms:

- path: `type`, `op`, `scope`, and either `root_key` plus `relative` for
  `scope:"workspace"`, or `path` for `scope:"outside"` or `"unknown"`;
- command: `type`, `kind`, argv fields, shell `text`, or code `language` plus
  `source`, and required `execution` and `cwd`;
- network: `type`, `protocol`, `host`, and optional `port`;
- custom: `type`, `name`, and optional `subject`.

Custom matchers select host-defined operations by exact name and optional exact
subject. Custom facts are always custom; read, write, command, and network
semantics use their built-in representations:

```json
{
  "type": "custom",
  "name": "shell.escalate",
  "subject": "git status"
}
```

The subject is exact; there is no custom-subject prefix syntax. Omitting it
matches every subject for that custom operation and is correspondingly broader.

## Complete example

This user config denies every operation on `.env`, always reviews accesses
under `secrets`, permits the `dune build` command family, and permits HTTPS web
access to one host:

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
        "action": "review",
        "matcher": {
          "type": "path-under-relative",
          "relative": "secrets"
        }
      },
      {
        "action": "allow",
        "matcher": {
          "type": "command",
          "pattern": {
            "type": "argv-prefix",
            "execution": {
              "kind": "enforced",
              "read": "project",
              "write": "workspace",
              "network": "restricted"
            },
            "cwd": { "type": "workspace" },
            "program": "dune",
            "args": ["build"]
          }
        }
      },
      {
        "action": "allow",
        "matcher": {
          "type": "network-host",
          "protocol": "https",
          "host": "docs.example.com"
        }
      }
    ]
  }
}
```

After editing, run `spice permission list --json` to verify evaluation order,
source, storage location, and the normalized rule encoding. Use
`spice config show --origins` to confirm that no workspace rule was dropped or
other config input degraded.
