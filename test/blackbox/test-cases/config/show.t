Spice config show renders text and JSON views of the effective config.

  $ git init -q

With no optional fields configured, text output contains resolved defaults.

  $ spice config show
  workspace_trust=trusted
  tui.thinking=true
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

Set values for the rendered views.

  $ spice config set model openai/gpt-5.5
  $ spice config set small_model openai/gpt-5.4-mini
  $ spice config set run.max_steps 9
  $ spice config set permission.mode plan
  $ spice config set shell /bin/bash
  $ spice config set providers.openrouter.base_url https://openrouter.example/api/v1
  $ spice config set providers.openai.base_url https://api.openai.example/v1

Text output is stable and ordered by provider id.

  $ spice config show
  workspace_trust=trusted
  model=openai/gpt-5.5
  small_model=openai/gpt-5.4-mini
  tui.thinking=true
  providers.openai.base_url=https://api.openai.example/v1
  providers.openrouter.base_url=https://openrouter.example/api/v1
  run.max_steps=9
  permission.mode=plan
  shell=/bin/bash
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

Origin output explains where effective values came from.

  $ spice config show --origins
  workspace_trust=trusted
    source: user workspace trust store
  model=openai/gpt-5.5
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  small_model=openai/gpt-5.4-mini
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  tui.thinking=true
    source: default built-in tui.thinking
  providers.openai.base_url=https://api.openai.example/v1
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  providers.openrouter.base_url=https://openrouter.example/api/v1
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  run.max_steps=9
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  permission.mode=plan
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  shell=/bin/bash
    source: user $TESTCASE_ROOT/xdg-config/spice/config.json
  notices.fswatch=true
    source: default built-in notices.fswatch
  notices.cr_comments=true
    source: default built-in notices.cr_comments
  notices.dune_diagnostics=true
    source: default built-in notices.dune_diagnostics
  notices.dune_build=true
    source: default built-in notices.dune_build
  instructions.global=true
    source: default built-in instructions.global
  instructions.project=true
    source: default built-in instructions.project
  instructions.claude_md=true
    source: default built-in instructions.claude_md
  instructions.project_max_bytes=32768
    source: default built-in instructions.project_max_bytes
  skills.enabled=true
    source: default built-in skills.enabled
  skills.builtin=true
    source: default built-in skills.builtin
  skills.project=true
    source: default built-in skills.project
  skills.compat=true
    source: default built-in skills.compat
  skills.disabled=[]
    source: default built-in skills.disabled
  skills.paths=[]
    source: default built-in skills.paths
  skills.catalog_max_bytes=8192
    source: default built-in skills.catalog_max_bytes
  tools.anchored_edits=false
    source: default built-in tools.anchored_edits
  web.enabled=false
    source: default built-in web.enabled
  web.allow_private_network=false
    source: default built-in web.allow_private_network
  web.search_backend=disabled
    source: default built-in web.search_backend
  web.fetch_max_bytes=5242880
    source: default built-in web.fetch_max_bytes
  web.output_max_chars=100000
    source: default built-in web.output_max_chars
  web.timeout_ms=30000
    source: default built-in web.timeout_ms
  web.max_timeout_ms=120000
    source: default built-in web.max_timeout_ms

JSON output has a stable shape.

  $ spice config show --json
  {"cwd":"$TESTCASE_ROOT","project_root":"$TESTCASE_ROOT","workspace_trust":"trusted","data_home":"$TESTCASE_ROOT/xdg-data/spice","state_home":"$TESTCASE_ROOT/xdg-state/spice","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","files":{"user":"$TESTCASE_ROOT/xdg-config/spice/config.json","project":"$TESTCASE_ROOT/.spice/config.json","project_local":"$TESTCASE_ROOT/.spice/config.local.json"},"model":"openai/gpt-5.5","small_model":"openai/gpt-5.4-mini","reasoning":null,"run":{"max_steps":9},"tui":{"thinking":true},"notices":{"fswatch":true,"cr_comments":true,"dune_diagnostics":true,"dune_build":true},"permission":{"mode":"plan"},"shell":"/bin/bash","instructions":{"global":true,"project":true,"claude_md":true,"project_max_bytes":32768},"skills":{"enabled":true,"builtin":true,"project":true,"compat":true,"paths":[],"catalog_max_bytes":8192},"tools":{"anchored_edits":false},"web":{"enabled":false,"allow_private_network":false,"search_backend":"disabled","fetch_max_bytes":5242880,"output_max_chars":100000,"timeout_ms":30000,"max_timeout_ms":120000},"providers":{"openai":{"base_url":"https://api.openai.example/v1"},"openrouter":{"base_url":"https://openrouter.example/api/v1"}}}

JSON origin output has a stable envelope and includes shadowed sources.

  $ SPICE_MODEL=openai/env-model spice config show --json --origins | grep -o '"schema_version":1,"type":"config_show"'
  "schema_version":1,"type":"config_show"

  $ SPICE_MODEL=openai/env-model spice config show --json --origins | grep -o '"diagnostics":\[\]'
  "diagnostics":[]

  $ SPICE_MODEL=openai/env-model spice config show --json --origins | grep -o '"model":"openai/env-model"'
  "model":"openai/env-model"

  $ SPICE_MODEL=openai/env-model spice config show --json --origins | sed -E 's#"path":"[^"]+"#"path":"$PATH"#g' | grep -F -o '"model":{"source":{"kind":"env","name":"SPICE_MODEL"},"shadowed":[{"kind":"user","path":"$PATH"}]}'
  "model":{"source":{"kind":"env","name":"SPICE_MODEL"},"shadowed":[{"kind":"user","path":"$PATH"}]}

JSON get emits JSON values.

  $ spice config get --json model
  "openai/gpt-5.5"

  $ spice config get --json run.max_steps
  9

  $ spice config unset model
  $ spice config get --json model
  null

Project config applies without any trust decision, and a clean load carries
no diagnostics.

  $ spice config set --project model openai/gpt-5.4
  $ spice config get model
  openai/gpt-5.4

  $ spice config show --json --origins | grep -o '"diagnostics":\[\]'
  "diagnostics":[]
