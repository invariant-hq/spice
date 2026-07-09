Spice config help documents the supported keys, source and target flags, JSON
output, and strict validation in user-facing language. Help output is long, so
these checks grep for the load-bearing pieces instead of pinning full pages,
and use --help=plain so the rendering does not depend on the terminal.

The command group help lists every supported config key with its vocabulary.

  $ spice config --help=plain | grep -o 'CONFIG KEYS'
  CONFIG KEYS

  $ spice config --help=plain | grep -cE '^       (model|small_model|reasoning|run.max_steps|permission.mode|shell)$'
  6

  $ spice config --help=plain | grep -o 'providers.ID.base_url'
  providers.ID.base_url

Enum-valued keys spell out their allowed values.

  $ spice config --help=plain | grep -o 'none, minimal, low, medium, high, xhigh'
  none, minimal, low, medium, high, xhigh

  $ spice config --help=plain | grep -o 'default, accept-edits, or plan'
  default, accept-edits, or plan

  $ spice config --help=plain | grep -o 'is available only through the per-run --permission-mode flag'
  is available only through the per-run --permission-mode flag

The group help explains the editing targets, including project-local.

  $ spice config --help=plain | grep -o 'CONFIG TARGETS'
  CONFIG TARGETS

  $ spice config --help=plain | grep -o 'gitignored project-local' | head -n 1
  gitignored project-local

Get documents effective versus source-specific reads and the JSON output flag.

  $ spice config get --help=plain | grep -o 'CONFIG SOURCES'
  CONFIG SOURCES

  $ spice config get --help=plain | grep -o 'reads the effective configuration'
  reads the effective configuration

  $ spice config get --help=plain | grep -cE '^       --(user|project|project-local)$'
  3

  $ spice config get --help=plain | grep -o 'Print machine-readable JSON.'
  Print machine-readable JSON.

Set documents the same keys and the user/project/project-local targets.

  $ spice config set --help=plain | grep -o 'CONFIG KEYS'
  CONFIG KEYS

  $ spice config set --help=plain | grep -o 'CONFIG TARGETS'
  CONFIG TARGETS

  $ spice config set --help=plain | grep -cE '^       --(user|project|project-local)$'
  3

Show documents its JSON and origins flags.

  $ spice config show --help=plain | grep -cE '^       --(json|origins)$'
  2

  $ spice config show --help=plain | grep -o 'Show the source of each effective config value.'
  Show the source of each effective config value.

Validate documents strict unknown-field rejection.

  $ spice config validate --help=plain | grep -cE '^       --strict$'
  1

  $ spice config validate --help=plain | grep -o 'Reject unknown fields'
  Reject unknown fields

The precedence order is documented in user-facing language on the config
group and show help pages: user file, project file, project-local file,
SPICE_CONFIG, environment, then runtime overrides — with the workspace
allowlist called out.

  $ spice config --help=plain | grep -c 'CONFIG PRECEDENCE'
  1

  $ spice config show --help=plain | grep -o 'increasing precedence'
  increasing precedence

  $ spice config show --help=plain | grep -o 'workspace-safe allowlist'
  workspace-safe allowlist
