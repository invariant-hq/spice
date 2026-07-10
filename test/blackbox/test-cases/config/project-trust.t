Project config applies without a trust decision.

Workspace config layers load unconditionally; safety comes from the
allowlist filter, not from a trust gate.

  $ spice config set --project model openai/gpt-5.4
  $ spice config get model
  openai/gpt-5.4

Trusting from a subdirectory and through a symlink resolves to the same
canonical project root.

  $ mkdir -p nested/.git nested/lib
  $ spice trust nested/lib
  trusted $TESTCASE_ROOT/nested
  $ ln -s nested nested-link
  $ spice untrust nested-link/lib
  untrusted $TESTCASE_ROOT/nested
  $ grep -o 'nested' "$XDG_CONFIG_HOME/spice/trust.json" | wc -l | tr -d ' '
  1

Concurrent writers preserve both decisions instead of replacing one writer's
snapshot with the other.

  $ mkdir -p root-a/.git root-b/.git
  $ spice trust root-a > root-a.out & root_a_pid=$!
  $ spice untrust root-b > root-b.out & root_b_pid=$!
  $ wait "$root_a_pid" && wait "$root_b_pid"
  $ cat root-a.out root-b.out
  trusted $TESTCASE_ROOT/root-a
  untrusted $TESTCASE_ROOT/root-b
  $ sed "s#$PWD#<root>#g" "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":2,"workspaces":{"<root>/nested":"untrusted","<root>/root-a":"trusted","<root>/root-b":"untrusted"}}

  $ spice config show --json --origins | grep -o '"diagnostics":\[\]'
  "diagnostics":[]

The trust store records an explicit versioned decision for the canonical root.

  $ spice trust .
  trusted $TESTCASE_ROOT
  $ sed "s#$PWD#<root>#g" "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":2,"workspaces":{"<root>":"trusted","<root>/nested":"untrusted","<root>/root-a":"trusted","<root>/root-b":"untrusted"}}
  $ find "$XDG_CONFIG_HOME/spice" -prune -perm 0700 -exec basename {} \;
  spice
  $ find "$XDG_CONFIG_HOME/spice/trust.json" "$XDG_CONFIG_HOME/spice/trust.json.lock" -prune -perm 0600 -exec basename {} \; | sort
  trust.json
  trust.json.lock

  $ spice config get model
  openai/gpt-5.4

  $ spice untrust .
  untrusted $TESTCASE_ROOT
  $ sed "s#$PWD#<root>#g" "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":2,"workspaces":{"<root>":"untrusted","<root>/nested":"untrusted","<root>/root-a":"trusted","<root>/root-b":"untrusted"}}

  $ spice config get model
  openai/gpt-5.4

Unsupported store versions fail closed and leave the original bytes intact.

  $ printf '{"version":1,"workspaces":{}}\n' > "$XDG_CONFIG_HOME/spice/trust.json"
  $ spice trust .
  spice: could not decode workspace trust store $TESTCASE_ROOT/xdg-config/spice/trust.json: unsupported version 1; expected version 2
  [1]
  $ cat "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":1,"workspaces":{}}
