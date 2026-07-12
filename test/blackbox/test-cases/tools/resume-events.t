Tool events derive from live executions only: a blocked run emits no tool
events and performs no mutation, the continuation that allows the tool
emits each event exactly once, and a later resume never re-emits events for
work that already finished. Counts are asserted instead of full lines so
the contract stays robust to additive fields.

The file-mutation editor is model-conditional (a GPT model would receive the
apply_patch family, without write_file). This case is about tool-event
lifecycle, not editor selection, so it pins the string-replace family
explicitly; the model stays gpt-5.5 for the fake OpenAI-Responses backend.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "review",
  >     "matcher": { "type": "path-workspace", "op": "create" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace

  $ cat > blocked.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-block-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-block-1","call_id":"call-block-1","name":"write_file","arguments":"{\"path\":\"guarded.txt\",\"contents\":\"guarded\\n\"}"}]}}
  > JSONL

  $ start_fake_openai blocked.jsonl capture-blocked port-blocked
  $ spice run --cwd "$PWD" --json --id resume-events "write the guarded file" > run1.out 2>run1.err; echo "exit:$?"
  exit:3
  $ wait_fake_server
  $ grep -c '"type":"tool\.' run1.out
  0
  [1]
  $ grep -c '"type":"workspace\.changed"' run1.out
  0
  [1]
  $ grep -o '"type":"session.waiting"' run1.out
  "type":"session.waiting"
  $ test ! -e guarded.txt

The continuation that allows the permission runs the tool once and emits
exactly one started, finished, and workspace event.

  $ permission_id=$(spice session show --json resume-events | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > allowed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-block-1"]},"response":{"id":"resp-block-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"guarded written"}]}]}}
  > JSONL
  $ start_fake_openai allowed.jsonl capture-allowed port-allowed
  $ spice run reply resume-events --cwd "$PWD" --json --allow "$permission_id" > run2.out 2>run2.err; echo "exit:$?"
  exit:0
  $ wait_fake_server
  $ grep -c '"type":"tool.started"' run2.out
  1
  $ grep -c '"type":"tool.finished"' run2.out
  1
  $ grep -c '"type":"workspace.changed"' run2.out
  1
  $ cat guarded.txt
  guarded

A later resume with a new prompt re-emits nothing for the finished tool.

  $ cat > followup.jsonl <<'JSONL'
  > {"expect":{"body_contains":["follow up"]},"response":{"id":"resp-follow-1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"nothing else"}]}]}}
  > JSONL
  $ start_fake_openai followup.jsonl capture-follow port-follow
  $ spice run resume resume-events --cwd "$PWD" --json "follow up" > run3.out 2>run3.err; echo "exit:$?"
  exit:0
  $ wait_fake_server
  $ grep -c '"type":"tool\.' run3.out
  0
  [1]
  $ grep -c '"type":"workspace\.changed"' run3.out
  0
  [1]
