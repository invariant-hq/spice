Spice does not migrate, alias, or normalize legacy reference-agent config
shapes. Unknown fields are preserved by non-strict edits and rejected loudly
by strict validation.

Write a user config holding plausible legacy fields next to a supported one.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<EOF
  > {"model":"openai/gpt-5.5","approval_policy":"never","model_reasoning_effort":"high","small_fast_model":"x"}
  > EOF

Effective loading still works and silently ignores the legacy fields: no
permission mode, reasoning effort, or small model is derived from them.

  $ spice config get model
  openai/gpt-5.5

  $ spice config show
  workspace_trust=trusted
  model=openai/gpt-5.5
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

Legacy names are not addressable keys and gain no compatibility alias.

  $ spice config get approval_policy
  Usage: spice config get [--help] [OPTION]… KEY
  spice: KEY argument: unknown config key: approval_policy Hint: supported
         keys: model, small_model, reasoning, providers.<provider>.base_url,
         tui.thinking, run.max_steps, run.subagent_max_concurrent,
         run.subagent_max_depth, run.subagent_wake, run.subagent_max_exchanges,
         permission.mode, permission.unattended, sandbox.mode, sandbox.require,
         sandbox.read, sandbox.readable_roots, sandbox.writable_roots,
         sandbox.network, shell, compaction.auto, notices.fswatch,
         notices.cr_comments, notices.dune_diagnostics, notices.dune_build,
         workspace.tooling, instructions.global, instructions.project,
         instructions.claude_md, instructions.project_max_bytes,
         skills.enabled, skills.builtin, skills.project, skills.compat,
         skills.disabled, skills.paths, skills.catalog_max_bytes,
         tools.anchored_edits, tools.editor, ocaml.merlin_program, web.enabled,
         web.allow_private_network, web.search_backend, web.fetch_max_bytes,
         web.output_max_chars, web.timeout_ms, web.max_timeout_ms
  [124]

A typed edit rewrites the file canonically but preserves every unknown field
with its value intact, so hand-authored data is never lost.

  $ spice config set model anthropic/claude-sonnet-4-6
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"small_fast_model":"x","model_reasoning_effort":"high","approval_policy":"never","model":"anthropic/claude-sonnet-4-6"}

  $ spice config get model
  anthropic/claude-sonnet-4-6

Default validation tolerates the unknown fields for preservation, but strict
validation rejects the file naming each unknown field.

  $ spice config validate "$XDG_CONFIG_HOME/spice/config.json"
  ok

  $ spice config validate --strict "$XDG_CONFIG_HOME/spice/config.json"
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json unknown field: small_fast_model
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json unknown field: model_reasoning_effort
  spice: $TESTCASE_ROOT/xdg-config/spice/config.json unknown field: approval_policy
  [1]
