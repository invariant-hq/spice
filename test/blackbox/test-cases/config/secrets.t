Spice config output never prints credential material, even when credential
environment variables are set in the invoking environment.

  $ git init -q

  $ export OPENAI_API_KEY=sk-SECRET-SENTINEL
  $ export ANTHROPIC_API_KEY=sk-ant-SECRET-SENTINEL

Give the config real values so every output path has content to leak through.

  $ spice config set model openai/gpt-5.5
  $ spice config set providers.openai.base_url https://api.openai.example/v1

Text output reports paths, selectors, and endpoints only.

  $ spice config show
  model=openai/gpt-5.5
  tui.thinking=true
  providers.openai.base_url=https://api.openai.example/v1
  permission.mode=default
  shell=/bin/sh
  notices.fswatch=true
  notices.cr_comments=true
  notices.dune_diagnostics=true
  notices.dune_build=true
  instructions.global=true
  instructions.project=true
  instructions.claude_md=true
  instructions.project_max_bytes=32768
  skills.enabled=true
  skills.builtin=true
  skills.project=true
  skills.compat=true
  skills.disabled=[]
  skills.paths=[]
  skills.catalog_max_bytes=8192
  tools.anchored_edits=false
  web.enabled=false
  web.allow_private_network=false
  web.search_backend=disabled
  web.fetch_max_bytes=5242880
  web.output_max_chars=100000
  web.timeout_ms=30000
  web.max_timeout_ms=120000

  $ spice config show 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

  $ spice config show --origins 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

The JSON envelope may name the auth store path, but never its contents or the
credential environment values.

  $ spice config show --json 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

  $ spice config show --json --origins 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

Get output prints the requested value only.

  $ spice config get model 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

  $ spice config get --json providers.openai.base_url 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

Config errors stay credential-free as well: break the user config file and
check the failure diagnostics.

  $ printf 'not json\n' > "$XDG_CONFIG_HOME/spice/config.json"
  $ spice config show
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json: Expected u while parsing null but found: o
  File "-", line 1, characters 0-2:
  [1]

  $ spice config show 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]

  $ spice config get model 2>&1 | grep -c SECRET-SENTINEL
  0
  [1]
