Cancelling a child parked on `message_parent` settles it durably exactly once,
acknowledges the cancellation to the parent, publishes the title-only settlement
notice, and makes later waits observe the cancelled terminal state. Repeating
the cancellation returns that same settlement without another transition.

  $ export SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=10

  $ cat > cancel.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"spawn_subagent\""],"body_not_contains":["subagent explore launched"]},"response":{"id":"resp-cancel-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cancel-spawn","call_id":"cancel-spawn","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Ask before continuing\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Ask before continuing","\"name\":\"message_parent\""]},"response":{"id":"resp-cancel-child-ask","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cancel-question","call_id":"cancel-question","name":"message_parent","arguments":"{\"message\":\"Should I continue?\"}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session cancel-parent-sub-cancel-spawn)"],"body_not_contains":["child session asked"]},"response":{"id":"resp-cancel-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cancel-wait","call_id":"cancel-wait","name":"wait_subagents","arguments":"{\"runs\":[\"cancel-parent-sub-cancel-spawn\"]}"}]}}
  > {"expect":{"body_contains":["child session asked: Should I continue?"]},"response":{"id":"resp-cancel-call","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cancel-call","call_id":"cancel-call","name":"cancel_subagent","arguments":"{\"run\":\"cancel-parent-sub-cancel-spawn\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","cancel-call","subagent explore cancelled (session cancel-parent-sub-cancel-spawn).","source: subagents","severity: warning","title: subagent explore cancelled (session cancel-parent-sub-cancel-spawn)"]},"response":{"id":"resp-cancel-repeat","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cancel-repeat","call_id":"cancel-repeat","name":"cancel_subagent","arguments":"{\"run\":\"cancel-parent-sub-cancel-spawn\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","cancel-repeat","subagent explore cancelled (session cancel-parent-sub-cancel-spawn)."]},"response":{"id":"resp-cancel-wait-again","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cancel-wait-again","call_id":"cancel-wait-again","name":"wait_subagents","arguments":"{\"runs\":[\"cancel-parent-sub-cancel-spawn\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","cancel-wait-again","child session cancelled"]},"response":{"id":"resp-cancel-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Cancellation observed."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai cancel.jsonl cancel-capture cancel-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id cancel-parent "delegate then cancel" 2>&1 | grep -o '"final_text":"Cancellation observed."'
  "final_text":"Cancellation observed."
  $ wait_fake_server
  $ spice session show --json cancel-parent | grep -o '"status":{"type":"cancelled"'
  "status":{"type":"cancelled"
  $ spice session export cancel-parent-sub-cancel-spawn | grep -o '"type":"turn_finished"' | wc -l | tr -d ' '
  1
  $ spice session export cancel-parent-sub-cancel-spawn | grep -o '"type":"interrupted"' | wc -l | tr -d ' '
  1

An explicitly parked child has no Live owner after its parent process exits.
Cancelling that hydrated Blocked record takes the durable recovery branch once;
repeating the operation returns the same record without another settlement
notice or fabricated child-session terminal event.

  $ cat > ownerless-park.jsonl <<'JSONL'
  > {"expect":{"body_contains":["park a recoverable child","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-ownerless-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ownerless-spawn","call_id":"ownerless-spawn","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Ask before process exit\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Ask before process exit","\"name\":\"message_parent\""]},"response":{"id":"resp-ownerless-ask","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ownerless-ask","call_id":"ownerless-ask","name":"message_parent","arguments":"{\"message\":\"Still needed?\"}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session ownerless-parent-sub-ownerless-spawn)"]},"response":{"id":"resp-ownerless-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ownerless-wait","call_id":"ownerless-wait","name":"wait_subagents","arguments":"{\"runs\":[\"ownerless-parent-sub-ownerless-spawn\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","ownerless-wait","child session asked: Still needed?"]},"response":{"id":"resp-ownerless-parked","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Ownerless child parked."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai ownerless-park.jsonl ownerless-park-capture ownerless-park-port
  $ spice run --json --cwd "$PWD" --permission-mode bypass --id ownerless-parent "park a recoverable child" 2>&1 | grep -o '"final_text":"Ownerless child parked."'
  "final_text":"Ownerless child parked."
  $ wait_fake_server
  $ grep -o '"type":"blocked"' $SPICE_TEST_DATA_HOME/subagents/ownerless-parent/ownerless-parent-sub-ownerless-spawn.json
  "type":"blocked"

  $ cat > ownerless-cancel.jsonl <<'JSONL'
  > {"expect":{"body_contains":["cancel the recovered child","\"name\":\"cancel_subagent\""]},"response":{"id":"resp-ownerless-cancel","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ownerless-cancel","call_id":"ownerless-cancel","name":"cancel_subagent","arguments":"{\"run\":\"ownerless-parent-sub-ownerless-spawn\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","ownerless-cancel","subagent explore cancelled (session ownerless-parent-sub-ownerless-spawn).","title: subagent explore cancelled (session ownerless-parent-sub-ownerless-spawn)"],"body_not_contains":["ownerless-repeat"]},"response":{"id":"resp-ownerless-repeat","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ownerless-repeat","call_id":"ownerless-repeat","name":"cancel_subagent","arguments":"{\"run\":\"ownerless-parent-sub-ownerless-spawn\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","ownerless-repeat","subagent explore cancelled (session ownerless-parent-sub-ownerless-spawn)."]},"response":{"id":"resp-ownerless-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Ownerless cancellation observed."}]}]}}
  > JSONL
  $ start_fake_openai ownerless-cancel.jsonl ownerless-cancel-capture ownerless-cancel-port
  $ spice run resume ownerless-parent --cwd "$PWD" "cancel the recovered child" 2>&1 | grep -o 'Ownerless cancellation observed.'
  Ownerless cancellation observed.
  $ wait_fake_server
  $ grep -o '"type":"cancelled"' $SPICE_TEST_DATA_HOME/subagents/ownerless-parent/ownerless-parent-sub-ownerless-spawn.json | wc -l | tr -d ' '
  1
  $ grep -o 'title: subagent explore cancelled (session ownerless-parent-sub-ownerless-spawn)' ownerless-cancel-capture/request-2.json | wc -l | tr -d ' '
  1
  $ spice session export ownerless-parent-sub-ownerless-spawn | grep -c '"type":"turn_finished"' || true
  0
  $ spice session export ownerless-parent-sub-ownerless-spawn | grep -c '"type":"interrupted"' || true
  0
