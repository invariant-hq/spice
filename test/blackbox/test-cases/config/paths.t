Spice config paths are resolved from an isolated test environment.

  $ git init -q

The user config defaults to XDG config home.

  $ spice config path
  $TESTCASE_ROOT/xdg-config/spice/config.json

  $ spice config path --user
  $TESTCASE_ROOT/xdg-config/spice/config.json

Project config files live under the workspace-local [.spice] directory.

  $ spice config path --project
  $TESTCASE_ROOT/.spice/config.json

  $ spice config path --project-local
  $TESTCASE_ROOT/.spice/config.local.json

Nested commands keep using the nearest Git project root.

  $ mkdir -p lib/nested
  $ cd lib/nested
  $ spice config path --project
  $TESTCASE_ROOT/.spice/config.json
  $ cd ../..

[SPICE_CONFIG_HOME] redirects the user config root.

  $ SPICE_CONFIG_HOME="$PWD/custom-config" spice config path
  $TESTCASE_ROOT/custom-config/config.json

Authority paths fail closed instead of falling through to another variable or
the current repository.

  $ SPICE_CONFIG_HOME=relative spice config path
  spice: SPICE_CONFIG_HOME must be an absolute path: relative
  [1]

  $ env -u SPICE_CONFIG_HOME -u XDG_CONFIG_HOME -u HOME spice config path
  spice: cannot determine Spice config home; set SPICE_CONFIG_HOME or an absolute HOME
  [1]

  $ mkdir -p .config/spice
  $ printf '{"version":2,"workspaces":{"%s":"trusted"}}\n' "$PWD" > .config/spice/trust.json
  $ env -u SPICE_CONFIG_HOME -u XDG_CONFIG_HOME -u HOME spice trust .
  spice: cannot determine Spice config home; set SPICE_CONFIG_HOME or an absolute HOME
  [1]
  $ test -f .config/spice/trust.json && echo repository-store-ignored
  repository-store-ignored

Target flags are mutually exclusive.

  $ spice config path --user --project
  spice: choose only one config target
  [124]

  $ spice config path --project --project-local
  spice: choose only one config target
  [124]
