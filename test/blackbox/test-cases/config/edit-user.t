Spice config edits user configuration through typed keys.

Initialize the user config file.

  $ spice config init
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {}

Set and read scalar values.

  $ spice config set model openai/gpt-5.5
  $ spice config get model
  openai/gpt-5.5

  $ spice config set small_model openai/gpt-5.4-mini
  $ spice config get small_model
  openai/gpt-5.4-mini

  $ spice config set reasoning high
  $ spice config get reasoning
  high
  $ spice config get --user --json reasoning
  "high"

  $ spice config set shell /bin/bash
  $ spice config get shell
  /bin/bash

  $ spice config set run.max_steps 12
  $ spice config get run.max_steps
  12
  $ spice config get --user --json run.max_steps
  12

Boolean instruction keys accept exactly true or false and render as JSON
booleans.

  $ spice config set instructions.project false
  $ spice config get instructions.project
  false
  $ spice config get --user --json instructions.project
  false

  $ spice config set instructions.project_max_bytes 1024
  $ spice config get instructions.project_max_bytes
  1024

Effective instruction keys resolve built-in defaults; layer reads do not.

  $ spice config get instructions.global
  true
  $ spice config get --user instructions.global
  spice: instructions.global is not set
  [1]
  $ spice config get --user --json instructions.global
  null

Provider keys are namespaced by provider id.

  $ spice config set providers.openai.base_url https://api.openai.example/v1
  $ spice config get providers.openai.base_url
  https://api.openai.example/v1

  $ spice config set providers.openrouter.base_url https://openrouter.example/api/v1
  $ spice config get providers.openrouter.base_url
  https://openrouter.example/api/v1

Unset removes persisted values.

  $ spice config unset model
  $ spice config get model
  spice: model is not set
  [1]

  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"small_model":"openai/gpt-5.4-mini","reasoning":"high","shell":"/bin/bash","run":{"max_steps":12},"instructions":{"project_max_bytes":1024,"project":false},"providers":{"openrouter":{"base_url":"https://openrouter.example/api/v1"},"openai":{"base_url":"https://api.openai.example/v1"}}}

Unsetting nested values removes empty containers.

  $ spice config unset reasoning
  $ spice config unset run.max_steps
  $ spice config unset instructions.project
  $ spice config unset instructions.project_max_bytes
  $ spice config unset providers.openrouter.base_url
  $ spice config unset providers.openai.base_url
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"small_model":"openai/gpt-5.4-mini","shell":"/bin/bash"}
