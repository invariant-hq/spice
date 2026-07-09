Headless exec handles workflow host tools that do not need user input.

`todo_write` updates session-local workflow state and returns a model-visible
tool result, so it must not block unattended exec runs.

  $ cat > todo.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.5\"","\"name\":\"todo_write\""]},"response":{"id":"resp-todo","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-todo","call_id":"todo-1","name":"todo_write","arguments":"{\"todos\":[{\"id\":\"inspect\",\"owner\":\"main\",\"content\":\"Inspect the project\",\"status\":\"in_progress\",\"priority\":\"high\",\"position\":0}]}"}]}}
  > {"expect":{"body_contains":["function_call_output","todo-1","Todo list updated: 1 items."]},"response":{"id":"resp-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Todo recorded."}]}]}}
  > JSONL
  $ start_fake_openai todo.jsonl todo-capture todo-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id todo-run "track the work" 2>&1 | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"todo-run","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"todo-run","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"todo-run","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"Todo recorded.","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":2,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  spice: session saved; resume with: spice resume 'todo-run'
  $ wait_fake_server

The todo sidecar was persisted and the session did not block.

  $ spice session show --json todo-run | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"todo-run","title":null,"preview":"track the work","lifecycle":"active","phase":"idle","forked_from":null,"event_count":5,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":79,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000},"workflow":{"plans":[],"todos":[{"id":"inspect","owner":"main","content":"Inspect the project","status":"in_progress","priority":"high","position":0}],"subagents":[]}}
  $ grep -o '"type":"function_call_output"' todo-capture/request-2.json
  "type":"function_call_output"
  $ grep -o '"call_id":"todo-1"' todo-capture/request-2.json
  "call_id":"todo-1"
  "call_id":"todo-1"
  $ grep -o 'Todo list updated: 1 items.' todo-capture/request-2.json
  Todo list updated: 1 items.

`propose_plan` is a blocking host-tool boundary: the proposal is saved
`proposed` and the turn parks exactly like a question, so a single model request
is sent and headless exec exits with the blocked status. The approval flow
arrives with the plan continuation flags in a later step.

  $ cat > plan.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"propose_plan\""],"body_not_contains":["\"name\":\"todo_write\""]},"response":{"id":"resp-plan","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-plan","call_id":"plan-1","name":"propose_plan","arguments":"{\"id\":\"milestone-plan\",\"title\":\"Milestone Plan\",\"body\":\"- Inspect host workflow\\n- Patch bounded gaps\"}"}]}}
  > JSONL
  $ start_fake_openai plan.jsonl plan-capture plan-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --mode plan --id plan-run "plan the work" 2>&1 | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"turn":"turn_[^"]+"/"turn":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"plan-run","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"plan-run","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"plan","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"session.waiting","session_id":"plan-run","revision":"sha256:$HASH","waiting":{"kind":"host_tool","turn":"turn_$ID","tool_call_id":"plan-1","tool":"propose_plan"},"metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":0,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  spice: session blocked
  [3]
  $ wait_fake_server

The plan sidecar was persisted as `proposed` and the session parked on the
`propose_plan` host-tool boundary; no second model request was sent.

  $ spice session show --json plan-run | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"active_turn":"turn_[^"]+"/"active_turn":"turn_$ID"/; s/"turn":"turn_[^"]+"/"turn":"turn_$ID"/g; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"plan-run","title":null,"preview":"plan the work","lifecycle":"active","phase":"waiting","forked_from":null,"event_count":2,"active_turn":"turn_$ID","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":"openai/responses:gpt-5.5","last_outcome":null,"waiting":{"kind":"host_tool","turn":"turn_$ID","tool_call_id":"plan-1","tool":"propose_plan"},"workflow_mode":"plan"},"latest_compaction":null,"context":{"projected_input_tokens_estimate":68,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000},"workflow":{"plans":[{"id":"milestone-plan","source":{"session":"plan-run","turn":"turn_$ID","tool_call_id":"plan-1"},"title":"Milestone Plan","body":"- Inspect host workflow\n- Patch bounded gaps","status":{"type":"proposed"},"created_at":$TIME}],"todos":[],"subagents":[]}}

Plan ids are scoped to their session. A second session can independently use
the same model-authored id without conflicting with the first session's plan.

  $ cat > plan-two.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"propose_plan\""]},"response":{"id":"resp-plan-two","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-plan-two","call_id":"plan-2","name":"propose_plan","arguments":"{\"id\":\"milestone-plan\",\"title\":\"Second Plan\",\"body\":\"- Work independently\"}"}]}}
  > JSONL
  $ start_fake_openai plan-two.jsonl plan-two-capture plan-two-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --mode plan --id plan-run-two "plan other work" 2>&1 | grep -o '"type":"session.waiting"'
  "type":"session.waiting"
  [3]
  $ wait_fake_server
  $ spice session show --json plan-run | grep -o '"source":{"session":"plan-run"' | head -1
  "source":{"session":"plan-run"
  $ spice session show --json plan-run-two | grep -o '"source":{"session":"plan-run-two"' | head -1
  "source":{"session":"plan-run-two"

`spawn_subagent` launches a detached child session: the spawn returns a
launch acknowledgment immediately, the parent turn continues while the
child explores with read-only tools, and the process exits only once the
child has settled — so the run ledger records the completed child and its
summary after the run. The parent's post-spawn request races the child's
first request, so the fake server matches script items by content.

  $ cat > subagent.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"spawn_subagent\""],"body_not_contains":["subagent explore launched"]},"response":{"id":"resp-subagent","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-subagent","call_id":"subagent-1","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Map host workflow UI\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Map host workflow UI"],"body_not_contains":["subagent explore launched"]},"response":{"id":"resp-subagent-child","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"child exploration findings"}]}]}}
  > {"expect":{"body_contains":["function_call_output","subagent-1","subagent explore launched"]},"response":{"id":"resp-subagent-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Delegated."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai subagent.jsonl subagent-capture subagent-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id subagent-run "delegate exploration" 2>&1 | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"subagent-run","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"subagent-run","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"subagent-run","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"Delegated.","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":2,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  spice: session saved; resume with: spice resume 'subagent-run'
  $ wait_fake_server

The child settled before the process exited: the ledger records the
completed run with the child's final text as its summary.

  $ spice session show --json subagent-run | grep -o '"role":"explore"'
  "role":"explore"
  $ spice session show --json subagent-run | grep -o '"status":{"type":"completed"' | head -1
  "status":{"type":"completed"
  $ spice session show --json subagent-run | grep -o '"summary":"child exploration findings"'
  "summary":"child exploration findings"

`wait_subagents` closes the loop: the deterministic child id from the
launch acknowledgment lets the model block for the result and read the
child's findings in the same turn.

  $ cat > subagent-wait.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"wait_subagents\""],"body_not_contains":["subagent explore launched"]},"response":{"id":"resp-w-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-w-spawn","call_id":"subagent-w1","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Survey the run ledger\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Survey the run ledger"]},"response":{"id":"resp-w-child","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ledger survey findings"}]}]}}
  > {"expect":{"body_contains":["subagent explore launched (session wait-run-sub-subagent-w1)"]},"response":{"id":"resp-w-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-w-wait","call_id":"wait-1","name":"wait_subagents","arguments":"{\"runs\":[\"wait-run-sub-subagent-w1\"]}"}]}}
  > {"expect":{"body_contains":["subagent explore completed","ledger survey findings"]},"response":{"id":"resp-w-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Waited."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai subagent-wait.jsonl wait-capture wait-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id wait-run "delegate then wait" 2>&1 | grep -o '"outcome":"completed","final_text":"Waited."'
  "outcome":"completed","final_text":"Waited."
  $ wait_fake_server
  $ grep -o 'ledger survey findings' wait-capture/request-4.json | head -1
  ledger survey findings

`message_parent` / `message_subagent` close the ask loop: the child parks
on its question, the parent's wait surfaces it as the blocker, the
parent's reply resumes the parked call with the answer as its result,
and a second wait collects the completed run.

  $ cat > subagent-ask.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"message_subagent\""],"body_not_contains":["subagent explore launched"]},"response":{"id":"resp-a-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-a-spawn","call_id":"ask-1","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Check the config default\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Check the config default","\"name\":\"message_parent\""],"body_not_contains":["wait_subagents"]},"response":{"id":"resp-a-child-ask","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-a-q","call_id":"q-1","name":"message_parent","arguments":"{\"message\":\"shared or worktree?\"}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session ask-run-sub-ask-1)"],"body_not_contains":["child session asked"]},"response":{"id":"resp-a-wait1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-a-w1","call_id":"w-1","name":"wait_subagents","arguments":"{\"runs\":[\"ask-run-sub-ask-1\"]}"}]}}
  > {"expect":{"body_contains":["child session asked: shared or worktree?"]},"response":{"id":"resp-a-reply","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-a-m","call_id":"m-1","name":"message_subagent","arguments":"{\"run\":\"ask-run-sub-ask-1\",\"message\":\"Shared is the default.\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Shared is the default.","function_call_output"],"body_not_contains":["wait_subagents"]},"response":{"id":"resp-a-child-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Config default is shared."}]}]}}
  > {"expect":{"body_contains":["subagent resumed with your message"]},"response":{"id":"resp-a-wait2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-a-w2","call_id":"w-2","name":"wait_subagents","arguments":"{\"runs\":[\"ask-run-sub-ask-1\"]}"}]}}
  > {"expect":{"body_contains":["subagent explore completed","Config default is shared."]},"response":{"id":"resp-a-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answered."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai subagent-ask.jsonl ask-capture ask-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id ask-run "delegate and answer" 2>&1 | grep -o '"outcome":"completed","final_text":"Answered."'
  "outcome":"completed","final_text":"Answered."
  $ wait_fake_server

The run resumed after the ask and settled completed with the child's
final text as its summary.

  $ spice session show --json ask-run | grep -o '"summary":"Config default is shared."'
  "summary":"Config default is shared."
