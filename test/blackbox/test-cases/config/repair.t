Spice config repair commands do not require effective config resolution.

  $ git init -q

Path discovery works even when an unrelated environment config value is
invalid.

  $ SPICE_MAX_STEPS=abc spice config path
  $TESTCASE_ROOT/xdg-config/spice/config.json

Editing one file also works with invalid effective environment config.

  $ SPICE_MAX_STEPS=abc spice config set model openai/gpt-5.5
  $ spice config get model
  openai/gpt-5.5

Unset is a no-op when the key is absent and the file does not exist.

  $ rm "$XDG_CONFIG_HOME/spice/config.json"
  $ test -e "$XDG_CONFIG_HOME/spice/config.json" || echo missing
  missing
  $ spice config unset model
  $ test -e "$XDG_CONFIG_HOME/spice/config.json" || echo still-missing
  still-missing

Initialization creates missing files but does not rewrite existing files.

  $ spice config init
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {}

  $ printf '{"unknown":true}\n' > "$XDG_CONFIG_HOME/spice/config.json"
  $ spice config init
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"unknown":true}

Command-line scalar values are parsed as shell strings, not as JSON.

  $ spice config set model openai/gpt-5.4
  $ spice config get model
  openai/gpt-5.4
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"unknown":true,"model":"openai/gpt-5.4"}
