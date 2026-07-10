Cancelling a child parked on `message_parent` settles it durably, acknowledges
the cancellation to the parent, publishes the title-only settlement notice,
and makes later waits observe the cancelled terminal state. Repeating the
cancellation returns that same settlement without another transition.

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
