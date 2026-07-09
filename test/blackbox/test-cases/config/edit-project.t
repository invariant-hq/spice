Spice config edits project and project-local files separately.

  $ git init -q

Shared project config is writable and applies immediately: workspace layers
load unconditionally, reduced to the workspace-safe allowlist.

  $ spice config init --project
  $ cat .spice/config.json
  {}

  $ spice config set --project model openai/gpt-5.4
  $ cat .spice/config.json
  {"model":"openai/gpt-5.4"}

  $ spice config get --project model
  openai/gpt-5.4

  $ spice config get model
  openai/gpt-5.4

Project-local config is writable and takes precedence over the shared file.

  $ spice config init --project-local
  $ cat .spice/config.local.json
  {}

  $ spice config set --project-local model openai/gpt-5.2
  $ cat .spice/config.local.json
  {"model":"openai/gpt-5.2"}

  $ spice config get --project-local model
  openai/gpt-5.2

  $ spice config get model
  openai/gpt-5.2

Source flags are mutually exclusive for reads.

  $ spice config get --user --project model
  spice: choose only one config source
  [124]
