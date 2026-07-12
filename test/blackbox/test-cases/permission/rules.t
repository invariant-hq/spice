Durable permission rules are hand-authored config facts: portable matcher
forms, content-derived ids that survive file reordering, inspection in
evaluation order, and removal that edits exactly one config file.

The product table is visible and owns native workspace operations.

  $ spice permission list | grep 'path-workspace'
  1   be7bf2b60ce9  allow   path-workspace op=read                   default product permission policy
  2   2d2b3c417b9f  allow   path-workspace op=create                 default product permission policy
  3   7c47a4047294  allow   path-workspace op=modify                 default product permission policy
  4   7f2fea3aff85  allow   path-workspace op=delete                 default product permission policy

Hand-written rules list before product rules, in file order. Relative path
matchers carry no machine-derived workspace key.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "path-under-relative", "relative": "notes" } },
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list | sed -n '2,4p'
  1   a8623e11d63d  allow   path-under-relative relative=notes       user $TESTCASE_ROOT/xdg-config/spice/config.json
  2   b62807796201  deny    path-exact-relative relative=.env        user $TESTCASE_ROOT/xdg-config/spice/config.json
  3   be7bf2b60ce9  allow   path-workspace op=read                   default product permission policy

Reordering changes positions but not ids because identity comes from content.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } },
  >   { "action": "allow",
  >     "matcher": { "type": "path-under-relative", "relative": "notes" } } ] } }
  > JSON
  $ spice permission list | sed -n '2,3p'
  1   b62807796201  deny    path-exact-relative relative=.env        user $TESTCASE_ROOT/xdg-config/spice/config.json
  2   a8623e11d63d  allow   path-under-relative relative=notes       user $TESTCASE_ROOT/xdg-config/spice/config.json
  $ spice permission list --json | grep -o '"id":"[^"]*"' | head -2
  "id":"b62807796201"
  "id":"a8623e11d63d"

Duplicate ids and invalid rule JSON fail at the configuration boundary.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny", "matcher": { "type": "path-exact-relative", "relative": ".env" } },
  >   { "action": "deny", "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json permission.rules contains duplicate rule b62807796201
  [1]
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "maybe", "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list 2>&1 | head -1
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json permission.rules: Unexpected permission rule action enum string value: maybe. Must be allow,
  [1]

The scalar config editor does not address structured rules. Editing another
permission key preserves them.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny", "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice config get permission.rules 2>&1 | grep 'permission rules are structured'
         permission rules are structured config: edit the config file directly,
  [124]
  $ spice config set permission.unattended deny
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"permission":{"rules":[{"action":"deny","matcher":{"type":"path-exact-relative","relative":".env"}}],"unattended":"deny"}}

Removal edits only the durable file. Fixed product rules are not removable.

  $ spice permission remove b62807796201
  removed rule b62807796201 from user $TESTCASE_ROOT/xdg-config/spice/config.json
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"permission":{"unattended":"deny"}}
  $ spice permission remove be7bf2b60ce9
  spice: no durable permission rule be7bf2b60ce9; run `spice permission list` to see rule ids
  [1]

Workspace files never contribute permission rules. They are stripped with a
diagnostic, while the user layer remains effective and removable.

  $ mkdir -p .spice
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny", "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ cat > .spice/config.json <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow", "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice permission list | sed -n '2p'
  1   b62807796201  deny    path-exact-relative relative=.env        user $TESTCASE_ROOT/xdg-config/spice/config.json
  $ spice config show --json --origins | grep -o '"kind":"ignored_project_rules"'
  "kind":"ignored_project_rules"
  $ spice permission remove b62807796201
  removed rule b62807796201 from user $TESTCASE_ROOT/xdg-config/spice/config.json
  $ grep -o '"action": "allow"' .spice/config.json
  "action": "allow"
  $ rm -f .spice/config.json

The unattended policy remains durable. Review bypass is only a per-run CLI
choice; the obsolete permission.mode shape fails loudly and gains no decoder.

  $ spice config get permission.unattended
  block
  $ SPICE_PERMISSION_UNATTENDED=block spice config get permission.unattended
  block
  $ SPICE_PERMISSION_UNATTENDED=never spice config get permission.unattended
  spice: unknown permission unattended policy: never
  Hint: expected one of: block, deny
  [1]
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "mode": "accept-edits" } }
  > JSON
  $ spice config validate 2>&1 | grep 'permission.mode is no longer supported'
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json permission.mode is no longer supported; use --permission bypass for one run
  [1]
