Spice config paths are resolved from an isolated test environment.

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

[SPICE_CONFIG_HOME] redirects the user config root.

  $ SPICE_CONFIG_HOME="$PWD/custom-config" spice config path
  $TESTCASE_ROOT/custom-config/config.json

Target flags are mutually exclusive.

  $ spice config path --user --project
  spice: choose only one config target
  [124]

  $ spice config path --project --project-local
  spice: choose only one config target
  [124]
