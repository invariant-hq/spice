A child the parent explicitly waits to completion remains actionable after the
parent process exits. The next host process hydrates the durable run and
`wait_subagents` returns its recorded result.

  $ export SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=10

  $ cat > launch.jsonl <<'JSONL'
  > {"expect":{"body_contains":["launch recoverable child","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-recovery-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-recovery-spawn","call_id":"recover-child","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Record durable findings\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Record durable findings"]},"response":{"id":"resp-recovery-child","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"durable child findings"}]}]}}
  > {"expect":{"body_contains":["subagent explore launched (session recovery-parent-sub-recover-child)"]},"response":{"id":"resp-recovery-parent-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-recovery-parent-wait","call_id":"recover-launch-wait","name":"wait_subagents","arguments":"{\"runs\":[\"recovery-parent-sub-recover-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","recover-launch-wait","subagent explore completed","durable child findings"]},"response":{"id":"resp-recovery-parent","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Child launched."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai launch.jsonl launch-capture launch-port
  $ spice run --json --cwd "$PWD" --permission bypass --id recovery-parent "launch recoverable child" 2>&1 | grep -o '"final_text":"Child launched."'
  "final_text":"Child launched."
  $ wait_fake_server
  $ grep -o '"summary":"durable child findings"' $SPICE_TEST_DATA_HOME/subagents/recovery-parent/recovery-parent-sub-recover-child.json
  "summary":"durable child findings"

  $ cat > collect.jsonl <<'JSONL'
  > {"expect":{"body_contains":["collect the durable child","\"name\":\"wait_subagents\""]},"response":{"id":"resp-recovery-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-recovery-wait","call_id":"recover-wait","name":"wait_subagents","arguments":"{\"runs\":[\"recovery-parent-sub-recover-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","recover-wait","subagent explore completed","durable child findings"]},"response":{"id":"resp-recovery-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered child result."}]}]}}
  > JSONL
  $ start_fake_openai collect.jsonl collect-capture collect-port
  $ spice run resume recovery-parent --cwd "$PWD" "collect the durable child" 2>&1 | grep -o 'Recovered child result.'
  Recovered child result.
  $ wait_fake_server

Messaging the same terminal child in another process rebuilds its runner from
the current turn and resumes the existing child session rather than creating a
second child.

  $ cat > resume.jsonl <<'JSONL'
  > {"expect":{"body_contains":["resume the durable child","\"name\":\"message_subagent\""]},"response":{"id":"resp-recovery-message","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-recovery-message","call_id":"recover-message","name":"message_subagent","arguments":"{\"run\":\"recovery-parent-sub-recover-child\",\"message\":\"Continue from the durable result\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Record durable findings","Continue from the durable result","durable child findings"]},"response":{"id":"resp-recovery-child-again","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second durable findings"}]}]}}
  > {"expect":{"body_contains":["function_call_output","recover-message","subagent resumed with your message"]},"response":{"id":"resp-recovery-wait-again","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-recovery-wait-again","call_id":"recover-wait-again","name":"wait_subagents","arguments":"{\"runs\":[\"recovery-parent-sub-recover-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","recover-wait-again","subagent explore completed","second durable findings"]},"response":{"id":"resp-recovery-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Resumed durable child."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai resume.jsonl resume-capture resume-port
  $ spice run resume recovery-parent --cwd "$PWD" "resume the durable child" 2>&1 | grep -o 'Resumed durable child.'
  Resumed durable child.
  $ wait_fake_server
  $ find $SPICE_TEST_DATA_HOME/subagents/recovery-parent -name '*.json' | wc -l | tr -d ' '
  1
  $ grep -o '"summary":"second durable findings"' $SPICE_TEST_DATA_HOME/subagents/recovery-parent/recovery-parent-sub-recover-child.json
  "summary":"second durable findings"

A queued or running ledger from a terminated host has no live owner. Addressing
it in a new process reconciles it to a durable failure instead of leaving a
permanent running ghost.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/recovery-parent-sub-orphan
  $ cat > $SPICE_TEST_DATA_HOME/sessions/recovery-parent-sub-orphan/session.json <<'JSON'
  > {"version":1,"id":"recovery-parent-sub-orphan","metadata":{"cwd":"/","title":"Orphaned child","status":"active","created_at":0,"updated_at":0},"events":[]}
  > JSON
  $ cat > $SPICE_TEST_DATA_HOME/subagents/recovery-parent/recovery-parent-sub-orphan.json <<'JSON'
  > {"child":"recovery-parent-sub-orphan","parent":"recovery-parent","parent_turn":"turn-orphan","parent_call_id":"orphan","spawn":{"role":"explore","task":"Outlive the host"},"depth":1,"status":{"type":"running","started_at":0},"created_at":0}
  > JSON
  $ cat > orphan.jsonl <<'JSONL'
  > {"expect":{"body_contains":["reconcile the orphan","\"name\":\"wait_subagents\""]},"response":{"id":"resp-orphan-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-orphan-wait","call_id":"orphan-wait","name":"wait_subagents","arguments":"{\"runs\":[\"recovery-parent-sub-orphan\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","orphan-wait","subagent explore did not complete","subagent run has no live owner"]},"response":{"id":"resp-orphan-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Orphan reconciled."}]}]}}
  > JSONL
  $ start_fake_openai orphan.jsonl orphan-capture orphan-port
  $ spice run resume recovery-parent --cwd "$PWD" "reconcile the orphan" 2>&1 | grep -o 'Orphan reconciled.'
  Orphan reconciled.
  $ wait_fake_server
  $ grep -o '"type":"failed"' $SPICE_TEST_DATA_HOME/subagents/recovery-parent/recovery-parent-sub-orphan.json
  "type":"failed"

A child the parent explicitly observes parked on `message_parent` also survives
process teardown. Its durable waiting boundary is reattached and answered in
place, so the resumed child finishes the original turn.

  $ cat > park.jsonl <<'JSONL'
  > {"expect":{"body_contains":["launch a parked child","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-park-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-park-spawn","call_id":"park-child","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Ask across a restart\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Ask across a restart","\"name\":\"message_parent\""]},"response":{"id":"resp-park-question","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-park-question","call_id":"park-question","name":"message_parent","arguments":"{\"message\":\"What is the answer?\"}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session parked-parent-sub-park-child)"]},"response":{"id":"resp-park-parent-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-park-parent-wait","call_id":"park-launch-wait","name":"wait_subagents","arguments":"{\"runs\":[\"parked-parent-sub-park-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","park-launch-wait","child session asked: What is the answer?"]},"response":{"id":"resp-park-parent","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Parked child launched."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai park.jsonl park-capture park-port
  $ spice run --json --cwd "$PWD" --permission bypass --id parked-parent "launch a parked child" 2>&1 | grep -o '"final_text":"Parked child launched."'
  "final_text":"Parked child launched."
  $ wait_fake_server
  $ grep -o '"type":"blocked"' $SPICE_TEST_DATA_HOME/subagents/parked-parent/parked-parent-sub-park-child.json
  "type":"blocked"

  $ cat > answer.jsonl <<'JSONL'
  > {"expect":{"body_contains":["answer the parked child","\"name\":\"message_subagent\""]},"response":{"id":"resp-park-message","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-park-message","call_id":"park-message","name":"message_subagent","arguments":"{\"run\":\"parked-parent-sub-park-child\",\"message\":\"Answer after restart\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Ask across a restart","Answer after restart","function_call_output"]},"response":{"id":"resp-park-child-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"parked child recovered"}]}]}}
  > {"expect":{"body_contains":["function_call_output","park-message","subagent resumed with your message"]},"response":{"id":"resp-park-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-park-wait","call_id":"park-wait","name":"wait_subagents","arguments":"{\"runs\":[\"parked-parent-sub-park-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","park-wait","subagent explore completed","parked child recovered"]},"response":{"id":"resp-park-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Parked child answered."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai answer.jsonl answer-capture answer-port
  $ spice run resume parked-parent --cwd "$PWD" "answer the parked child" 2>&1 | grep -o 'Parked child answered.'
  Parked child answered.
  $ wait_fake_server
  $ grep -o '"summary":"parked child recovered"' $SPICE_TEST_DATA_HOME/subagents/parked-parent/parked-parent-sub-park-child.json
  "summary":"parked child recovered"
