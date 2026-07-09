Workspace config is scoped to preferences.

Capability-shaped keys are rejected when writing either workspace file.

  $ spice config set --project shell /bin/bash
  spice: shell is not allowed in workspace config; allowed keys: model, small_model, reasoning, run.max_steps, permission.unattended, workspace.tooling, tools.editor, ocaml.merlin_program, web.search_backend, web.fetch_max_bytes, web.output_max_chars, web.timeout_ms, web.max_timeout_ms
  [2]

  $ spice config set --project permission.mode bypass
  spice: permission.mode is not allowed in workspace config; allowed keys: model, small_model, reasoning, run.max_steps, permission.unattended, workspace.tooling, tools.editor, ocaml.merlin_program, web.search_backend, web.fetch_max_bytes, web.output_max_chars, web.timeout_ms, web.max_timeout_ms
  [2]

  $ spice config set --project providers.openai.base_url https://repo.example/v1
  spice: providers.openai.base_url is not allowed in workspace config; allowed keys: model, small_model, reasoning, run.max_steps, permission.unattended, workspace.tooling, tools.editor, ocaml.merlin_program, web.search_backend, web.fetch_max_bytes, web.output_max_chars, web.timeout_ms, web.max_timeout_ms
  [2]

Project-local config is workspace content a repository can commit, so it
shares the same allowlist.

  $ spice config set --project-local shell /bin/bash
  spice: shell is not allowed in workspace config; allowed keys: model, small_model, reasoning, run.max_steps, permission.unattended, workspace.tooling, tools.editor, ocaml.merlin_program, web.search_backend, web.fetch_max_bytes, web.output_max_chars, web.timeout_ms, web.max_timeout_ms
  [2]

Hand-written workspace config applies only allowlisted keys; disallowed keys
are ignored with structured diagnostics, no trust decision required.

  $ mkdir -p .spice
  $ cat > .spice/config.json <<EOF
  > {"model":"openai/gpt-5.4","small_model":"openai/gpt-5.4-mini","reasoning":"medium","run":{"max_steps":5},"shell":"/bin/bash","providers":{"openai":{"base_url":"https://repo.example/v1"}}}
  > EOF

  $ spice config show --origins | grep -E '^(model|small_model|reasoning|run.max_steps)='
  model=openai/gpt-5.4
  small_model=openai/gpt-5.4-mini
  reasoning=medium
  run.max_steps=5

  $ spice config show --origins | grep -E '^shell=' | grep -v bash > /dev/null

  $ spice config show --origins | grep 'ignored in workspace config'
  diagnostic: project config key ignored in workspace config: providers.openai.base_url ($TESTCASE_ROOT/.spice/config.json)
  diagnostic: project config key ignored in workspace config: shell ($TESTCASE_ROOT/.spice/config.json)

  $ spice config show --json --origins | grep -o '"kind":"ignored_project_key"' | awk 'END { print NR }'
  2

A workspace file that names the bypass preset is rejected whole: bypass is
per-invocation, never durable, so the file degrades to an empty layer with a
diagnostic instead of applying partially.

  $ cat > .spice/config.json <<EOF
  > {"model":"openai/gpt-5.4","permission":{"mode":"bypass"}}
  > EOF

  $ spice config get model
  spice: model is not set
  [1]

  $ spice config show --json --origins | grep -o '"kind":"invalid_project_config"'
  "kind":"invalid_project_config"

Workspace permission rules never load: the one structured field that carries
authority is stripped with a diagnostic.

  $ cat > .spice/config.json <<'EOF'
  > {"model":"openai/gpt-5.4","permission":{"rules":[{"action":"allow","matcher":{"type":"command","pattern":{"type":"argv-prefix","program":"rm","args":[]}}}]}}
  > EOF

  $ spice config get model
  openai/gpt-5.4

  $ spice config show --json --origins | grep -o '"kind":"ignored_project_rules"'
  "kind":"ignored_project_rules"

Budget keys may tighten but not widen the non-workspace effective value.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"run":{"max_steps":10}}' > "$XDG_CONFIG_HOME/spice/config.json"
  $ cat > .spice/config.json <<EOF
  > {"run":{"max_steps":1000}}
  > EOF

  $ spice config get run.max_steps
  10

  $ spice config show --json --origins | grep -o '"kind":"ignored_project_budget"'
  "kind":"ignored_project_budget"

  $ cat > .spice/config.json <<EOF
  > {"run":{"max_steps":3}}
  > EOF

  $ spice config get run.max_steps
  3
