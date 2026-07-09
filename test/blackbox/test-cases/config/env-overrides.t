Environment variables override effective config without being persisted.

On Unix, COMSPEC from cross-platform environments does not override SHELL for
the default shell program.

  $ COMSPEC='C:\Windows\System32\cmd.exe' SHELL=/bin/zsh spice config get shell
  /bin/zsh

Seed user config with file values.

  $ spice config set model openai/gpt-5.4
  $ spice config set small_model openai/gpt-5.4-nano
  $ spice config set reasoning medium
  $ spice config set run.max_steps 7
  $ spice config set permission.mode plan
  $ spice config set shell /bin/bash
  $ spice config set providers.openai.base_url https://file.example/v1

Environment variables have higher precedence for reads.

  $ SPICE_MODEL=openai/env-model spice config get model
  openai/env-model

  $ SPICE_SMALL_MODEL=openai/env-small spice config get small_model
  openai/env-small

  $ SPICE_REASONING=xhigh spice config get reasoning
  xhigh

  $ SPICE_REASONING=extreme spice config get reasoning
  spice: unknown reasoning effort: extreme
  Hint: expected one of: none, minimal, low, medium, high, xhigh, max
  [1]

  $ SPICE_MAX_STEPS=22 spice config get run.max_steps
  22

  $ SPICE_MAX_STEPS=9007199254740992 spice config get run.max_steps
  spice: SPICE_MAX_STEPS must be at most 9007199254740991
  [1]

  $ SPICE_PERMISSION_MODE=bypass spice config get permission.mode
  spice: SPICE_PERMISSION_MODE must not be bypass
  Hint: pass --permission-mode bypass for one run
  [1]

  $ SPICE_SHELL=/bin/zsh spice config get shell
  /bin/zsh

  $ SPICE_OPENAI_BASE_URL=https://env.example/v1 spice config get providers.openai.base_url
  https://env.example/v1

  $ SPICE_OLLAMA_BASE_URL=http://127.0.0.1:8080 spice config get providers.ollama.base_url
  http://127.0.0.1:8080

Environment overrides are not persisted by edits.

  $ SPICE_MODEL=openai/env-model spice config set small_model openai/gpt-5.4-mini
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"model":"openai/gpt-5.4","small_model":"openai/gpt-5.4-mini","reasoning":"medium","shell":"/bin/bash","run":{"max_steps":7},"providers":{"openai":{"base_url":"https://file.example/v1"}},"permission":{"mode":"plan"}}
