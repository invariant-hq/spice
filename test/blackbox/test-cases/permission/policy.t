Durable rules and presets compose as one visible first-match order: durable
config rules decide before the preset — including denies under bypass — and
workspace files never contribute rules at all.

  $ git init -q

A hand-written portable rule allows the matching write without review. The
test directory is a fresh checkout every run, so this also pins that relative
path rules carry no machine-derived root key.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "path-under-relative", "relative": "notes" } } ] } }
  > JSON

The file-mutation editor is model-conditional (a GPT model receives the
apply_patch family, without edit_file/write_file), so these runs pin the
string-replace family explicitly; the model stays gpt-5.5 for the fake
OpenAI-Responses backend.

  $ spice config set tools.editor string-replace

  $ cat > allowed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-1","call_id":"call-allowed","name":"write_file","arguments":"{\"path\":\"notes/today.txt\",\"contents\":\"hello\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","created"]},"response":{"id":"resp-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"written"}]}]}}
  > JSONL
  $ start_fake_openai allowed.jsonl capture-allowed port-allowed
  $ spice run --cwd "$PWD" --id rule-allows "write notes/today.txt" 2>/dev/null; echo exit:$?
  • tool write_file running
  ✓ tool write_file notes/today.txt completed: A notes/today.txt
  changed 1 file (+1 -0)
  diff: spice session diff --latest 'rule-allows'
  revert: spice session revert --latest 'rule-allows'
  written
  exit:0
  $ wait_fake_server
  $ cat notes/today.txt
  hello

A durable deny rule denies under bypass: the preset is a baseline, not an
override of explicit policy. The model sees the denial; nothing blocks.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny",
  >     "matcher": { "type": "path-exact-relative", "relative": ".env" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace
  $ cat > bypass.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-3","call_id":"call-bypass","name":"write_file","arguments":"{\"path\":\".env\",\"contents\":\"SECRET=1\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","Permission denied by policy rule b62807796201 (user)."]},"response":{"id":"resp-4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"denied by policy"}]}]}}
  > JSONL
  $ start_fake_openai bypass.jsonl capture-bypass port-bypass
  $ spice run --cwd "$PWD" --permission-mode bypass --id deny-under-bypass "write .env" 2>/dev/null; echo exit:$?
  denied by policy
  exit:0
  $ wait_fake_server
  $ test -e .env || echo not-written
  not-written

A workspace allow rule never overrides a user deny: workspace files cannot
carry permission rules, so the user's deny still decides. The stripped rules
surface as a config diagnostic, not as policy.

  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "deny",
  >     "matcher": { "type": "path-under-relative", "relative": "build" } } ] } }
  > JSON
  $ mkdir -p .spice
  $ cat > .spice/config.json <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "path-under-relative", "relative": "build" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace
  $ cat > project.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-5","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-5","call_id":"call-project","name":"write_file","arguments":"{\"path\":\"build/out.txt\",\"contents\":\"ok\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","Permission denied by policy rule"]},"response":{"id":"resp-6","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"user deny held"}]}]}}
  > JSONL
  $ start_fake_openai project.jsonl capture-project port-project
  $ spice run --cwd "$PWD" --id project-over-user "write build/out.txt" 2>/dev/null; echo exit:$?
  user deny held
  exit:0
  $ wait_fake_server
  $ test -e build/out.txt || echo not-written
  not-written
  $ spice config show --json --origins | grep -o '"kind":"ignored_project_rules"'
  "kind":"ignored_project_rules"
  $ rm -f "$XDG_CONFIG_HOME/spice/config.json" .spice/config.json
  $ spice config set tools.editor string-replace

The plan preset denies commands outright with steering feedback instead of
parking headless planning on review; the run continues to completion.

  $ cat > plan.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-7","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-7","call_id":"call-plan","name":"shell","arguments":"{\"command\":\"ls\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","plan mode does not allow commands"]},"response":{"id":"resp-8","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"using read tools instead"}]}]}}
  > JSONL
  $ start_fake_openai plan.jsonl capture-plan port-plan
  $ spice run --cwd "$PWD" --permission-mode plan --id plan-commands "list files" 2>/dev/null; echo exit:$?
  using read tools instead
  exit:0
  $ wait_fake_server
  $ grep -o 'plan mode does not allow commands' capture-plan/request-2.json | head -1
  plan mode does not allow commands

Plan still allows workspace reads and blocks workspace writes as reviewable
denials, per the preset contract.

  $ cat > plan-write.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-9","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-9","call_id":"call-plan-write","name":"write_file","arguments":"{\"path\":\"plan.txt\",\"contents\":\"x\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","Permission denied by policy rule","(preset)."]},"response":{"id":"resp-10","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"cannot write in plan"}]}]}}
  > JSONL
  $ start_fake_openai plan-write.jsonl capture-plan-write port-plan-write
  $ spice run --cwd "$PWD" --permission-mode plan --id plan-write "write plan.txt" 2>/dev/null; echo exit:$?
  cannot write in plan
  exit:0
  $ wait_fake_server
  $ test -e plan.txt || echo not-written
  not-written
