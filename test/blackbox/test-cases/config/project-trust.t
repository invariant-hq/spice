Workspace config is inert until the exact canonical project root is trusted.
This case uses a nested repository and isolated config home so the harness's
trusted fixture root cannot leak into it.

  $ mkdir -p workspace/.git workspace/trust-config
  $ cd workspace
  $ export XDG_CONFIG_HOME="$PWD/trust-config"
  $ spice config set --project model openai/gpt-5.4
  $ spice config set --project-local small_model openai/gpt-5.4-mini
  $ printf 'REPOSITORY INSTRUCTION\n' > AGENTS.md
  $ mkdir -p .spice/skills/project-only relative-skills/relative-only ../outside-skills/outside-only
  $ cat > .spice/skills/project-only/SKILL.md <<'EOF'
  > ---
  > description: Project only.
  > ---
  > Project guidance.
  > EOF
  $ cat > relative-skills/relative-only/SKILL.md <<'EOF'
  > ---
  > description: Relative path inside the project.
  > ---
  > Relative guidance.
  > EOF
  $ cat > ../outside-skills/outside-only/SKILL.md <<'EOF'
  > ---
  > description: User path outside the project.
  > ---
  > Outside guidance.
  > EOF
  $ spice config set skills.paths "[\"relative-skills\",\"$PWD/../outside-skills\"]"
  $ spice config show --json | grep -o '"workspace_trust":"unknown"'
  "workspace_trust":"unknown"
  $ spice config show --json | grep -o '"model":null,"small_model":null'
  "model":null,"small_model":null
  $ spice config show --json --origins | grep -o '"kind":"project_config_disabled"' | wc -l | tr -d ' '
  2
  $ spice debug prompt | grep -c 'REPOSITORY INSTRUCTION' || true
  0
  $ spice skills list | grep -E 'outside-only|project-only|relative-only|project skills disabled'
    [1] outside-only  path  $TESTCASE_ROOT/outside-skills/outside-only
    project skills disabled: workspace is not trusted
  $ spice debug tools > unknown-tools.txt
  $ for tool in ocaml_dune_describe ocaml_dune_diagnostics ocaml_eval ocaml_docs ocaml_find_definitions ocaml_find_references ocaml_rename ocaml_type_at; do if grep -q "^## $tool$" unknown-tools.txt; then echo "unexpected: $tool"; fi; done
  $ grep -E '^## ocaml_(ast_edit|search_expressions|replace_expressions)$' unknown-tools.txt
  ## ocaml_ast_edit
  ## ocaml_replace_expressions
  ## ocaml_search_expressions

An unknown headless workspace stays useful but does not inject project inputs
or start automatic project processes.

  $ printf '(lang dune 3.0)\n' > dune-project
  $ mkdir -p _opam/bin
  $ cat > _opam/bin/dune <<'EOF'
  > #!/bin/sh
  > printf local-switch > "$LOCAL_SWITCH_MARKER"
  > EOF
  $ chmod +x _opam/bin/dune
  $ export LOCAL_SWITCH_MARKER="$PWD/local-switch-spawned"
  $ cat > unknown-shell.jsonl <<'EOF'
  > {"expect":{"body_contains":["try local dune","\"name\":\"shell\""]},"response":{"id":"resp-unknown-shell-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-unknown-shell","call_id":"call-unknown-shell","name":"shell","arguments":"{\"command\":\"dune --version\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-unknown-shell"]},"response":{"id":"resp-unknown-shell-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"restricted shell finished"}]}]}}
  > EOF
  $ start_fake_openai unknown-shell.jsonl unknown-shell-capture unknown-shell-port
  $ spice_bin=$(command -v spice)
  $ PATH=/usr/bin:/bin SPICE_WORKSPACE_TOOLING=off "$spice_bin" run --ephemeral --permission-mode bypass --sandbox danger-full-access "try local dune" 2>/dev/null | grep 'restricted shell finished'
  restricted shell finished
  $ wait_fake_server
  $ test ! -e "$LOCAL_SWITCH_MARKER" && echo no-local-switch-process
  no-local-switch-process
  $ mkdir fake-bin
  $ cat > fake-bin/dune <<'EOF'
  > #!/bin/sh
  > printf spawned > "$DUNE_MARKER"
  > exit 1
  > EOF
  $ chmod +x fake-bin/dune
  $ export DUNE_MARKER="$PWD/dune-spawned"
  $ export PATH="$PWD/fake-bin:$PATH"
  $ cat > unknown-run.jsonl <<'EOF'
  > {"expect":{"body_contains":["unknown trust prompt"],"body_not_contains":["REPOSITORY INSTRUCTION","project-only","relative-only"]},"response":{"id":"resp-unknown","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"restricted answer"}]}]}}
  > EOF
  $ start_fake_openai unknown-run.jsonl unknown-capture unknown-port
  $ spice run --ephemeral --permission-mode bypass "unknown trust prompt" > unknown.out 2> unknown.err
  $ grep -o 'workspace trust: unknown' unknown.err
  workspace trust: unknown
  $ test ! -e "$DUNE_MARKER" && echo no-project-process
  no-project-process
  $ grep 'restricted answer' unknown.out
  restricted answer
  $ wait_fake_server
  $ unset SPICE_MODEL

Trusting from a subdirectory activates both workspace layers without granting
fields outside the workspace allowlist.

  $ mkdir -p lib
  $ spice trust lib
  trusted $TESTCASE_ROOT/workspace
  $ spice config show --json | grep -o '"workspace_trust":"trusted"'
  "workspace_trust":"trusted"
  $ spice config get model
  openai/gpt-5.4
  $ spice config get small_model
  openai/gpt-5.4-mini
  $ spice debug prompt | grep 'REPOSITORY INSTRUCTION'
  REPOSITORY INSTRUCTION
  $ spice skills list | grep -E 'outside-only|project-only|relative-only'
    [1] project-only  project  $TESTCASE_ROOT/workspace/.spice/skills/project-only
    [2] relative-only  path  $TESTCASE_ROOT/workspace/relative-skills/relative-only
    [3] outside-only  path  $TESTCASE_ROOT/outside-skills/outside-only
  $ cat > trusted-shell.jsonl <<'EOF'
  > {"expect":{"body_contains":["use local dune","\"name\":\"shell\""]},"response":{"id":"resp-trusted-shell-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-trusted-shell","call_id":"call-trusted-shell","name":"shell","arguments":"{\"command\":\"dune --version\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-trusted-shell"]},"response":{"id":"resp-trusted-shell-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"trusted shell finished"}]}]}}
  > EOF
  $ start_fake_openai trusted-shell.jsonl trusted-shell-capture trusted-shell-port
  $ PATH=/usr/bin:/bin SPICE_WORKSPACE_TOOLING=off "$spice_bin" run --ephemeral --permission-mode bypass --sandbox danger-full-access "use local dune" 2>/dev/null | grep 'trusted shell finished'
  trusted shell finished
  $ wait_fake_server
  $ test -e "$LOCAL_SWITCH_MARKER" && echo local-switch-process-started
  local-switch-process-started
  $ cat > trusted-run.jsonl <<'EOF'
  > {"expect":{"body_contains":["trusted prompt","REPOSITORY INSTRUCTION","project-only","relative-only"]},"response":{"id":"resp-trusted","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"trusted answer"}]}]}}
  > EOF
  $ start_fake_openai trusted-run.jsonl trusted-capture trusted-port
  $ spice run --ephemeral --permission-mode bypass "trusted prompt" > trusted.out 2> trusted.err
  $ test -e "$DUNE_MARKER" && echo project-process-started
  project-process-started
  $ grep 'trusted answer' trusted.out
  trusted answer
  $ wait_fake_server
  $ unset SPICE_MODEL
  $ spice config set --project ocaml.merlin_program '["evil-merlin"]'
  spice: ocaml.merlin_program is not allowed in workspace config; allowed keys: model, small_model, reasoning, run.max_steps, permission.unattended, workspace.tooling, tools.editor, web.search_backend, web.fetch_max_bytes, web.output_max_chars, web.timeout_ms, web.max_timeout_ms
  [2]

Trust identities converge through symlinks, and untrust records an explicit
refusal with the same runtime behavior as an unknown workspace.

  $ cd ..
  $ ln -s workspace workspace-link
  $ spice untrust workspace-link/lib
  untrusted $TESTCASE_ROOT/workspace
  $ cd workspace
  $ spice config show --json | grep -o '"workspace_trust":"untrusted"'
  "workspace_trust":"untrusted"
  $ spice config show --json | grep -o '"model":null,"small_model":null'
  "model":null,"small_model":null
  $ rm -f "$DUNE_MARKER"
  $ cat > untrusted-run.jsonl <<'EOF'
  > {"expect":{"body_contains":["untrusted prompt"],"body_not_contains":["REPOSITORY INSTRUCTION","project-only","relative-only"]},"response":{"id":"resp-untrusted","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"untrusted answer"}]}]}}
  > EOF
  $ start_fake_openai untrusted-run.jsonl untrusted-capture untrusted-port
  $ spice run --ephemeral --permission-mode bypass "untrusted prompt" > untrusted.out 2> untrusted.err
  $ grep -o 'workspace trust: untrusted' untrusted.err
  workspace trust: untrusted
  $ test ! -e "$DUNE_MARKER" && echo no-project-process
  no-project-process
  $ grep 'untrusted answer' untrusted.out
  untrusted answer
  $ wait_fake_server
  $ sed "s#$PWD#<root>#g" "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":2,"workspaces":{"<root>":"untrusted"}}

Concurrent writers preserve both decisions instead of replacing one writer's
snapshot with the other.

  $ mkdir -p root-a/.git root-b/.git
  $ spice trust root-a > root-a.out & root_a_pid=$!
  $ spice untrust root-b > root-b.out & root_b_pid=$!
  $ wait "$root_a_pid" && wait "$root_b_pid"
  $ cat root-a.out root-b.out
  trusted $TESTCASE_ROOT/workspace/root-a
  untrusted $TESTCASE_ROOT/workspace/root-b
  $ sed "s#$PWD#<root>#g" "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":2,"workspaces":{"<root>":"untrusted","<root>/root-a":"trusted","<root>/root-b":"untrusted"}}
  $ find "$XDG_CONFIG_HOME/spice" -prune -perm 0700 -exec basename {} \;
  spice
  $ find "$XDG_CONFIG_HOME/spice/trust.json" "$XDG_CONFIG_HOME/spice/trust.json.lock" -prune -perm 0600 -exec basename {} \; | sort
  trust.json
  trust.json.lock
  $ find "$XDG_CONFIG_HOME/spice" -name 'trust.json.tmp.*'

Unsupported store versions fail closed and leave the original bytes intact.

  $ printf '{"version":1,"workspaces":{}}\n' > "$XDG_CONFIG_HOME/spice/trust.json"
  $ spice trust .
  spice: could not decode workspace trust store $TESTCASE_ROOT/workspace/trust-config/spice/trust.json: unsupported version 1; expected version 2
  [1]
  $ spice config show
  spice: could not decode workspace trust store $TESTCASE_ROOT/workspace/trust-config/spice/trust.json: unsupported version 1; expected version 2
  [1]
  $ spice doctor --json > doctor.json
  [1]
  $ grep -o '"name":"workspace trust","status":"fail"' doctor.json
  "name":"workspace trust","status":"fail"
  $ grep -o '"valid=false"' doctor.json
  "valid=false"
  $ spice config get --project model
  openai/gpt-5.4
  $ cat "$XDG_CONFIG_HOME/spice/trust.json"
  {"version":1,"workspaces":{}}
