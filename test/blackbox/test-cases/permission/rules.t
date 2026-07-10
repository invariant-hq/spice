Durable permission rules are hand-authored config facts: portable matcher
forms, content-derived ids that survive file reordering, inspection in
evaluation order, and removal that edits exactly one config file.

The list shows the active preset's rules even before any durable rule exists.

  $ spice permission list
  #  RULE          ACTION  MATCH                   SOURCE
  1  be7bf2b60ce9  allow   path-workspace op=read  preset permission.mode=default

Hand-written rules in the user config list before the preset, in file order,
with content-derived ids, source kind, and storage location. The relative
path form carries no machine-derived workspace root key.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "command", "pattern": { "type": "argv-prefix", "program": "dune", "args": ["build"] } } },
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list
  #  RULE          ACTION  MATCH                                                                     SOURCE
  1  39dabbb6bf76  allow   command pattern={"type":"argv-prefix","program":"dune","args":["build"]}  user $TESTCASE_ROOT/xdg-config/spice/config.json
  2  b62807796201  deny    path-exact-relative relative=.env                                         user $TESTCASE_ROOT/xdg-config/spice/config.json
  3  be7bf2b60ce9  allow   path-workspace op=read                                                    preset permission.mode=default

Reordering the file does not change rule ids: identity is derived from rule
content, never from position.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } },
  >   { "action": "allow",
  >     "matcher": { "type": "command", "pattern": { "type": "argv-prefix", "program": "dune", "args": ["build"] } } } ] } }
  > JSON
  $ spice permission list
  #  RULE          ACTION  MATCH                                                                     SOURCE
  1  b62807796201  deny    path-exact-relative relative=.env                                         user $TESTCASE_ROOT/xdg-config/spice/config.json
  2  39dabbb6bf76  allow   command pattern={"type":"argv-prefix","program":"dune","args":["build"]}  user $TESTCASE_ROOT/xdg-config/spice/config.json
  3  be7bf2b60ce9  allow   path-workspace op=read                                                    preset permission.mode=default

The JSON view mirrors the same rows with the rule's schema encoding.

  $ spice permission list --json
  {"schema_version":1,"type":"permission.rules","rules":[{"position":1,"id":"b62807796201","rule":{"action":"deny","matcher":{"type":"path-exact-relative","relative":".env"}},"source":"user","location":"$TESTCASE_ROOT/xdg-config/spice/config.json"},{"position":2,"id":"39dabbb6bf76","rule":{"action":"allow","matcher":{"type":"command","pattern":{"type":"argv-prefix","program":"dune","args":["build"]}}},"source":"user","location":"$TESTCASE_ROOT/xdg-config/spice/config.json"},{"position":3,"id":"be7bf2b60ce9","rule":{"action":"allow","matcher":{"type":"path-workspace","op":"read"}},"source":"preset","location":"permission.mode=default"}]}

Two identical rules in one layer are a load error naming the duplicate id,
before any command can run against the config.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } },
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json permission.rules contains duplicate rule b62807796201
  [1]

Invalid rule JSON fails loudly with the offending location.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [ { "action": "maybe",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json permission.rules: Unexpected permission rule action enum string value: maybe. Must be allow,
  review or deny.
  File "-":
  File "-": in member action of
  File "-": permission rule object
  File "-": at index 0 of
  File "-": array<permission rule object>
  [1]

The scalar config surface does not address the structured field; the error
points at the file and the permission commands.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice config get permission.rules
  Usage: spice config get [--help] [OPTION]… KEY
  spice: KEY argument: config key permission.rules is not a scalar value Hint:
         permission rules are structured config: edit the config file directly,
         then inspect with `spice permission list` and remove with `spice
         permission remove`
  [124]
  $ spice config set permission.rules '[]'
  Usage: spice config set [--help] [--project] [--project-local] [--user]
         [OPTION]… KEY VALUE
  spice: KEY argument: config key permission.rules is not a scalar value Hint:
         permission rules are structured config: edit the config file directly,
         then inspect with `spice permission list` and remove with `spice
         permission remove`
  [124]

Scalar edits through other permission keys preserve the structured rules.

  $ spice config set permission.mode accept-edits
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"permission":{"rules":[{"action":"deny","matcher":{"type":"path-exact-relative","relative":".env"}}],"mode":"accept-edits"}}
  $ spice config unset permission.mode

Removal edits exactly one file and drops the member when no rules remain.

  $ spice permission remove b62807796201
  removed rule b62807796201 from user $TESTCASE_ROOT/xdg-config/spice/config.json
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {}
  $ spice permission list
  #  RULE          ACTION  MATCH                   SOURCE
  1  be7bf2b60ce9  allow   path-workspace op=read  preset permission.mode=default

Unknown ids fail loudly, and preset rules are not removable.

  $ spice permission remove deadbeef0000
  spice: no durable permission rule deadbeef0000; run `spice permission list` to see rule ids
  [1]
  $ spice permission remove 7846a2b8d492
  spice: no durable permission rule 7846a2b8d492; run `spice permission list` to see rule ids
  [1]

Workspace files never contribute rules: rules in project or project-local
config are stripped at load with a diagnostic, never listed, and never
become effective policy. Only the user layer (and the preset) list.

  $ mkdir -p .spice
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "command", "pattern": { "type": "argv-prefix", "program": "dune", "args": ["build"] } } } ] } }
  > JSON
  $ cat > .spice/config.json <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "command", "pattern": { "type": "argv-prefix", "program": "dune", "args": ["build"] } } } ] } }
  > JSON
  $ cat > .spice/config.local.json <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "review",
  >     "matcher": { "type": "path-under-relative", "relative": "secrets" } } ] } }
  > JSON
  $ spice permission list
  #  RULE          ACTION  MATCH                                                                     SOURCE
  1  39dabbb6bf76  allow   command pattern={"type":"argv-prefix","program":"dune","args":["build"]}  user $TESTCASE_ROOT/xdg-config/spice/config.json
  2  be7bf2b60ce9  allow   path-workspace op=read                                                    preset permission.mode=default

The stripped workspace rules surface as config diagnostics, one per file.

  $ spice config show --json --origins | grep -o '"kind":"ignored_project_rules"' | awk 'END { print NR }'
  2

Removal never reaches workspace files: their rules are not durable policy,
so the ids resolve against the user layer only. The files stay hand-editable.

  $ spice permission remove 39dabbb6bf76
  removed rule 39dabbb6bf76 from user $TESTCASE_ROOT/xdg-config/spice/config.json
  $ spice permission list
  #  RULE          ACTION  MATCH                   SOURCE
  1  be7bf2b60ce9  allow   path-workspace op=read  preset permission.mode=default
  $ rm -f .spice/config.json .spice/config.local.json

The unattended reply policy is an ordinary enum key with a built-in default,
environment override, and validation.

  $ spice config get permission.unattended
  block
  $ SPICE_PERMISSION_UNATTENDED=deny spice config get permission.unattended
  deny
  $ SPICE_PERMISSION_UNATTENDED=never spice config get permission.unattended
  spice: unknown permission unattended policy: never
  Hint: expected one of: block, deny
  [1]
  $ spice config set permission.unattended deny
  $ spice config get permission.unattended
  deny
  $ spice config unset permission.unattended

The dangerous preset never survives a restart: every durable channel — the
environment and config files alike — rejects bypass with recovery guidance.
Only the per-invocation CLI flag reaches it.

  $ SPICE_PERMISSION_MODE=bypass spice config get permission.mode
  spice: SPICE_PERMISSION_MODE must not be bypass
  Hint: pass --permission-mode bypass for one run
  [1]
  $ SPICE_PERMISSION_MODE=plan spice config get permission.mode
  plan
  $ spice config set permission.mode bypass
  spice: permission.mode must not be bypass
  Hint: pass --permission-mode bypass for one run
  [2]
  $ spice config set permission.mode accept-edits
  $ spice config get permission.mode
  accept-edits
  $ spice config unset permission.mode
