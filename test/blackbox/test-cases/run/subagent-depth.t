Recursive delegation uses the same run tree. A child receives the collaboration
tools, its grandchild consumes the shared capacity, and the result is delivered
to the direct parent rather than leaking into the root session's notices.

  $ cat > recursive.jsonl <<'JSONL'
  > {"expect":{"body_contains":["delegate recursively","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-rec-root-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-root-spawn","call_id":"root-child","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Delegate the nested survey\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Delegate the nested survey","\"name\":\"spawn_subagent\"","\"name\":\"message_parent\""]},"response":{"id":"resp-rec-child-self-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-child-self-wait","call_id":"self-wait","name":"wait_subagents","arguments":"{\"runs\":[\"recursive-root-sub-root-child\"]}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session recursive-root-sub-root-child)"]},"response":{"id":"resp-rec-root-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-root-wait","call_id":"wait-root-child","name":"wait_subagents","arguments":"{\"runs\":[\"recursive-root-sub-root-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","self-wait","cannot target its own session"]},"response":{"id":"resp-rec-child-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-child-spawn","call_id":"nested-child","name":"spawn_subagent","arguments":"{\"role\":\"verify\",\"task\":\"Inspect the nested invariant\"}"}]}}
  > {"expect":{"body_contains":["Role: verify","Inspect the nested invariant"]},"response":{"id":"resp-rec-grandchild-ancestor-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-grandchild-ancestor-wait","call_id":"ancestor-wait","name":"wait_subagents","arguments":"{\"runs\":[\"recursive-root-sub-root-child\"]}"}]}}
  > {"expect":{"body_contains":["subagent verify launched (session recursive-root-sub-root-child-sub-nested-child)"]},"response":{"id":"resp-rec-child-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-child-wait","call_id":"wait-nested-child","name":"wait_subagents","arguments":"{\"runs\":[\"recursive-root-sub-root-child-sub-nested-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","ancestor-wait","is not a descendant of session recursive-root-sub-root-child-sub-nested-child"]},"response":{"id":"resp-rec-grandchild","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"nested result secret"}]}]}}
  > {"expect":{"body_contains":["subagent verify completed","nested result secret"]},"response":{"id":"resp-rec-child-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"recursive child complete"}]}]}}
  > {"expect":{"body_contains":["subagent explore completed","recursive child complete"],"body_not_contains":["nested result secret"]},"response":{"id":"resp-rec-root-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recursive delegation completed."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai recursive.jsonl recursive-capture recursive-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id recursive-root "delegate recursively" 2>&1 | grep -o '"final_text":"Recursive delegation completed."'
  "final_text":"Recursive delegation completed."
  $ wait_fake_server

The durable lineage records the immediate parent and the derived depth.

  $ grep -o '"parent":"recursive-root","parent_turn"' $SPICE_TEST_DATA_HOME/subagents/recursive-root/recursive-root-sub-root-child.json
  "parent":"recursive-root","parent_turn"
  $ grep -o '"parent":"recursive-root-sub-root-child","parent_turn"' $SPICE_TEST_DATA_HOME/subagents/recursive-root-sub-root-child/recursive-root-sub-root-child-sub-nested-child.json
  "parent":"recursive-root-sub-root-child","parent_turn"
  $ grep -o '"depth":2' $SPICE_TEST_DATA_HOME/subagents/recursive-root-sub-root-child/recursive-root-sub-root-child-sub-nested-child.json
  "depth":2

A later host process can still address the recursive descendant by its child
session id; lookup is tree-wide rather than incorrectly assuming every run is a
direct child of the resumed root.

  $ cat > recover-nested.jsonl <<'JSONL'
  > {"expect":{"body_contains":["recover nested result","\"name\":\"wait_subagents\""]},"response":{"id":"resp-rec-recover-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-recover-wait","call_id":"recover-nested","name":"wait_subagents","arguments":"{\"runs\":[\"recursive-root-sub-root-child-sub-nested-child\"]}"}]}}
  > {"expect":{"body_contains":["subagent verify completed","nested result secret"]},"response":{"id":"resp-rec-recover-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Nested result recovered."}]}]}}
  > JSONL
  $ start_fake_openai recover-nested.jsonl recover-nested-capture recover-nested-port
  $ spice run resume recursive-root --cwd "$PWD" "recover nested result" 2>&1 | grep -o 'Nested result recovered.'
  Nested result recovered.
  $ wait_fake_server

Knowing a child id does not grant another root session lifecycle authority over
that tree.

  $ cat > reject-foreign.jsonl <<'JSONL'
  > {"expect":{"body_contains":["target a foreign nested run","\"name\":\"wait_subagents\""]},"response":{"id":"resp-rec-foreign-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rec-foreign-wait","call_id":"foreign-nested","name":"wait_subagents","arguments":"{\"runs\":[\"recursive-root-sub-root-child-sub-nested-child\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","foreign-nested","is not a descendant of session foreign-root"]},"response":{"id":"resp-rec-foreign-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Foreign run rejected."}]}]}}
  > JSONL
  $ start_fake_openai reject-foreign.jsonl reject-foreign-capture reject-foreign-port
  $ spice run --json --cwd "$PWD" --permission-mode bypass --id foreign-root "target a foreign nested run" 2>&1 | grep -o '"final_text":"Foreign run rejected."'
  "final_text":"Foreign run rejected."
  $ wait_fake_server

The depth bound is checked before a grandchild session or ledger is minted.

  $ spice config set run.subagent_max_depth 1
  $ cat > depth-limit.jsonl <<'JSONL'
  > {"expect":{"body_contains":["exercise depth limit","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-depth-root-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-depth-root-spawn","call_id":"depth-a","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"Attempt one nested delegation\"}"}]}}
  > {"expect":{"body_contains":["Role: explore","Attempt one nested delegation","\"name\":\"spawn_subagent\""]},"response":{"id":"resp-depth-child-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-depth-child-spawn","call_id":"too-deep","name":"spawn_subagent","arguments":"{\"role\":\"verify\",\"task\":\"Must not be created\"}"}]}}
  > {"expect":{"body_contains":["subagent explore launched (session depth-root-sub-depth-a)"]},"response":{"id":"resp-depth-root-wait","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-depth-root-wait","call_id":"wait-depth-a","name":"wait_subagents","arguments":"{\"runs\":[\"depth-root-sub-depth-a\"]}"}]}}
  > {"expect":{"body_contains":["function_call_output","too-deep","subagent depth 2 exceeds the configured limit 1","run.subagent_max_depth"]},"response":{"id":"resp-depth-child-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"depth limit rejected the grandchild"}]}]}}
  > {"expect":{"body_contains":["subagent explore completed","depth limit rejected the grandchild"]},"response":{"id":"resp-depth-root-done","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Depth limit enforced."}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_UNORDERED=1 start_fake_openai depth-limit.jsonl depth-limit-capture depth-limit-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id depth-root "exercise depth limit" 2>&1 | grep -o '"final_text":"Depth limit enforced."'
  "final_text":"Depth limit enforced."
  $ wait_fake_server
  $ test ! -e $SPICE_TEST_DATA_HOME/sessions/depth-root-sub-depth-a-sub-too-deep/session.json && echo no-grandchild
  no-grandchild
