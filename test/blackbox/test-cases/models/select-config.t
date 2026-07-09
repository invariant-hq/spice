Spice models select writes the exact typed config keys that spice config get
reads, through the same config edit path.

  $ git init -q

A rejected selection does not create a config file.

  $ spice models select openai/no-such-model
  spice: unknown model "no-such-model" for provider "openai"
  [2]

  $ test -e "$XDG_CONFIG_HOME/spice/config.json" || echo "no config"
  no config

Selecting a main model writes the user `model` key.

  $ spice models select openai/gpt-5.5
  $ spice config get model
  openai/gpt-5.5
  $ spice config get --user model
  openai/gpt-5.5

--small writes the `small_model` key instead.

  $ spice models select --small openai/gpt-5.4-mini
  $ spice config get small_model
  openai/gpt-5.4-mini

  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"model":"openai/gpt-5.5","small_model":"openai/gpt-5.4-mini"}

The --project and --project-local targets write the workspace config files,
which stay readable by source flag even while the workspace is untrusted.

  $ spice models select --project anthropic/claude-sonnet-4-6
  $ spice config get --project model
  anthropic/claude-sonnet-4-6
  $ cat .spice/config.json
  {"model":"anthropic/claude-sonnet-4-6"}

  $ spice models select --project-local --small openai/gpt-5.4-nano
  $ spice config get --project-local small_model
  openai/gpt-5.4-nano
  $ cat .spice/config.local.json
  {"small_model":"openai/gpt-5.4-nano"}

Project layers participate in effective selection; unsafe members such as
permission rules are stripped at load boundaries instead.

  $ spice config get model
  anthropic/claude-sonnet-4-6

A rejected selection does not modify an existing config file either.

  $ spice models select --project nosuch/model-x
  spice: unknown provider "nosuch"
  [2]

  $ cat .spice/config.json
  {"model":"anthropic/claude-sonnet-4-6"}
