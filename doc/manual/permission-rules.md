# Permission rules

Durable permission rules are ordered, hand-authored JSON policy. Use them for a
specific exception that the built-in permission preset and sandbox-backed rules
do not express. Read [Security](security.md) first: a rule decides whether an
operation is allowed, reviewed, or denied, but it does not grant filesystem,
network, sandbox, or operating-system capabilities.

## Storage and precedence

Put rules under `permission.rules` in either:

- the user config, normally `$XDG_CONFIG_HOME/spice/config.json`;
- the extra config selected by `SPICE_CONFIG`.

The extra config's rules evaluate before user rules. Within one file, rules
evaluate in array order. They are followed by the active preset and then any
sandbox-backed runtime rules.

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
allowing every command suppresses the normal command review. Prefer the
narrowest matcher that describes the intended exception.

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

An argv-prefix rule matches a directly parsed command whose program is exact
and whose argument list starts with the supplied arguments:

```json
{
  "type": "command",
  "pattern": {
    "type": "argv-prefix",
    "program": "dune",
    "args": ["build"]
  }
}
```

This matches `dune build`, `dune build @fmt`, and `dune build lib/foo.cmxa`.
It does not match a different program spelling or a command that had to fall
back to an opaque shell-text access because parsing was ambiguous.

An argv prefix may restrict the command's working-directory scope with `cwd`:

```json
{
  "type": "command",
  "pattern": {
    "type": "argv-prefix",
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
{ "type": "command", "pattern": { "type": "sandboxed" } }
```

```json
{ "type": "command", "pattern": { "type": "destructive" } }
```

```json
{ "type": "command", "pattern": { "type": "any" } }
```

`sandboxed` matches only a host-produced command fact that proves ordinary
execution uses the run's sealed sandbox. It never infers confinement from the
program or source tool. The enforcing workspace-write posture uses this matcher
after its destructive-command review rule; direct routes and non-enforcing
postures get no such credit. An escalation request carries a direct ordinary
command fact plus the distinct `shell.escalate` custom access.

`destructive` is the conservative built-in classifier for recursive or forced
`rm`, force push, hard reset, forced clean, `dd`, `shred`, `mkfs`, `sudo`, and
`doas`. A non-match is not proof of safety. `any` matches every command access
and can shadow built-in safety rules when placed in durable config.

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
      "execution": "direct"
    }
  }
}
```

An exact shell access instead uses `"kind": "shell"` and a required `text`
field. Either command access requires `execution:"direct"` or
`execution:"sandboxed"` and may also carry a `cwd` scope. Execution route is
part of exact permission identity, so a grant for a sealed operation cannot be
reused by a direct one.

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
- command: `type`, `kind`, argv fields or shell `text`, required `execution`,
  and optional `cwd`;
- network: `type`, `protocol`, `host`, and optional `port`;
- custom: `type`, `kind`, `name`, and optional `subject`.

Custom matchers select host-defined operations by exact name, optional access
kind, and optional exact subject:

```json
{
  "type": "custom",
  "kind": "custom",
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
