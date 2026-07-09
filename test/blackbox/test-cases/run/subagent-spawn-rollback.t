A subagent spawn that cannot create its ledger record rolls back the child
session. Retrying the same opaque call id after storage recovers therefore
launches normally instead of colliding with an orphan.

  $ mkdir -p .spice
  $ printf blocked > .spice/subagents
  $ cat > failed-spawn.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"spawn_subagent\""]},"response":{"id":"resp-failed-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-failed-spawn","call_id":"retry-call","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Inspect after recovery\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","retry-call"],"body_not_contains":["subagent explore launched"]},"response":{"id":"resp-failed-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Spawn failed cleanly."}]}]}}
  > JSONL
  $ start_fake_openai failed-spawn.jsonl failed-spawn-capture failed-spawn-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id rollback-parent "delegate with broken storage" 2>&1 | grep -o '"final_text":"Spawn failed cleanly."'
  "final_text":"Spawn failed cleanly."
  $ wait_fake_server
  $ test ! -e .spice/sessions/rollback-parent-sub-retry-call/session.json && echo no-orphan
  no-orphan

  $ rm .spice/subagents
  $ cat > retry-spawn.jsonl <<'JSONL'
  > {"expect":{"body_contains":["retry","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-retry-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-retry-spawn","call_id":"retry-call","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Inspect after recovery\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Inspect after recovery"]},"response":{"id":"resp-retry-child","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"recovered child findings"}]}]}}
  > {"expect":{"body_contains":["function_call_output","retry-call","subagent explore launched"]},"response":{"id":"resp-retry-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Retry launched."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai retry-spawn.jsonl retry-spawn-capture retry-spawn-port

  $ spice run resume rollback-parent --cwd "$PWD" "retry" 2>&1 | grep -o 'Retry launched.'
  Retry launched.
  $ wait_fake_server
  $ spice session show --json rollback-parent | grep -o '"summary":"recovered child findings"'
  "summary":"recovered child findings"
