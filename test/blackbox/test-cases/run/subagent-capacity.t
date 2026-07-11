The subagent concurrency limit applies to every running episode. A blocked
child frees its slot, but cannot resume while another child holds that slot.

  $ spice config set run.subagent_max_concurrent 1
  $ cat > capacity.jsonl <<'JSONL'
  > {"expect":{"body_contains":["exercise subagent capacity","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-cap-spawn-a","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-spawn-a","call_id":"cap-a","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Ask before resuming\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Ask before resuming","\"name\":\"message_parent\""]},"response":{"id":"resp-cap-ask-a","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-ask-a","call_id":"cap-question","name":"message_parent","arguments":"{\"message\":\"May I resume?\"}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session capacity-parent-sub-cap-a)"]},"response":{"id":"resp-cap-wait-a","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-wait-a","call_id":"cap-wait","name":"wait_subagents","arguments":"{\"runs\":[\"capacity-parent-sub-cap-a\"]}"}]}}
  > {"expect":{"body_contains":["child session asked: May I resume?"]},"response":{"id":"resp-cap-spawn-b","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-spawn-b","call_id":"cap-b","name":"spawn_subagent","arguments":"{\"role\":\"verify\",\"task\":\"Hold the only running slot\"}"}]}}
  > {"expect":{"body_contains":["Role: verify","Hold the only running slot","\"name\":\"shell\""]},"response":{"id":"resp-cap-child-b-hold","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-child-b-hold","call_id":"cap-child-b-hold","name":"shell","arguments":"{\"command\":\"sleep 2\"}"}]}}
  > {"expect":{"body_contains":["subagent verify launched (session capacity-parent-sub-cap-b)"]},"response":{"id":"resp-cap-resume-a","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-resume-a","call_id":"cap-resume","name":"message_subagent","arguments":"{\"run\":\"capacity-parent-sub-cap-a\",\"message\":\"Resume now\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","cap-resume","1 subagents are already running","run.subagent_max_concurrent"]},"response":{"id":"resp-cap-wait-b","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cap-wait-b","call_id":"cap-wait-b","name":"wait_subagents","arguments":"{\"runs\":[\"capacity-parent-sub-cap-b\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","cap-child-b-hold","exited 0"]},"response":{"id":"resp-cap-child-b-finished","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second child finished"}]}]}}
  > {"expect":{"body_contains":["function_call_output","cap-wait-b","subagent verify completed","second child finished"]},"response":{"id":"resp-cap-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Capacity enforced."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai capacity.jsonl capacity-capture capacity-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id capacity-parent "exercise subagent capacity" 2>&1 | grep -o '"final_text":"Capacity enforced."'
  "final_text":"Capacity enforced."
  $ wait_fake_server

The refused child remains blocked, while the child that held the slot settles
normally.

  $ grep -o '"type":"blocked"' $SPICE_TEST_DATA_HOME/subagents/capacity-parent/capacity-parent-sub-cap-a.json
  "type":"blocked"
  $ grep -o '"type":"completed"' $SPICE_TEST_DATA_HOME/subagents/capacity-parent/capacity-parent-sub-cap-b.json
  "type":"completed"
