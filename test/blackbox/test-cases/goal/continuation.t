Goal-driven headless runs. `--goal` stores the artifact before the first turn,
so the run's catalog offers `update_goal` and the first request carries the
ephemeral goal-context notice. A clean turn end launches a continuation turn
whose input is the host continuation prompt and whose turn record carries the
`goal` origin; the model's `update_goal complete` transitions the artifact
inline and stops the loop.

  $ cat > goal.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"update_goal\"","Active session goal","Ship the goal feature"]},"response":{"id":"resp-1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working on it."}]}]}}
  > {"expect":{"body_contains":["Continue working toward the active session goal."],"body_not_contains":["Active session goal"]},"response":{"id":"resp-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-goal","call_id":"goal-call-1","name":"update_goal","arguments":"{\"status\":\"complete\",\"summary\":\"Delivered.\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","goal-call-1","Goal completed:"]},"response":{"id":"resp-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"All done."}]}]}}
  > JSONL
  $ start_fake_openai goal.jsonl goal-capture goal-port

  $ spice run --json --cwd "$PWD" --permission bypass --id goal-run --goal "Ship the goal feature" "start shipping" 2>&1 | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/; s/"goal_id":"goal_[^"]+"/"goal_id":"goal_$ID"/; s/"time_used_ms":[0-9]+/"time_used_ms":$TIME/'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","read":"all","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"goal-run","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"goal.set","session_id":"goal-run","goal_id":"goal_$ID","status":"active","objective":"Ship the goal feature","tokens_used":0,"time_used_ms":$TIME,"continuation_turns":0}
  {"schema_version":1,"type":"turn.started","session_id":"goal-run","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"goal-run","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"Working on it.","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  {"schema_version":1,"type":"turn.started","session_id":"goal-run","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","origin":"goal","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"goal.completed","session_id":"goal-run","goal_id":"goal_$ID","status":"completed","objective":"Ship the goal feature","tokens_used":0,"time_used_ms":$TIME,"continuation_turns":1}
  {"schema_version":1,"type":"turn.finished","session_id":"goal-run","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"All done.","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":3,"turns":2,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  spice: session saved; resume with: spice resume 'goal-run'
  $ wait_fake_server

The completed goal is terminal, so the workflow projection shows no goal.

  $ spice session show --json goal-run | grep -c '"goal"'
  0
  [1]

The continuation request carried the rendered continuation prompt and the
first request carried the goal tool and notice; the model saw the completion
confirmation as an ordinary tool result.

  $ grep -o 'Completion audit' goal-capture/request-2.json | head -1
  Completion audit
  $ grep -o '"name":"update_goal"' goal-capture/request-1.json | head -1
  "name":"update_goal"
