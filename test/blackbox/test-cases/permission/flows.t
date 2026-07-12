Blocked permission prompts carry the full review contract: review behavior,
each reviewed access with render-time policy provenance, and host-computed
planned-change evidence — in the human text, the status JSON, and the JSONL
events, from the same projection.

The file-mutation editor is model-conditional (a GPT model receives the
apply_patch family, without edit_file/write_file), so these runs pin the
string-replace family explicitly; the model stays gpt-5.5 for the fake
OpenAI-Responses backend.

  $ spice config set tools.editor string-replace
  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "review",
  >     "matcher": { "type": "path-workspace", "op": "create" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace

  $ cat > block.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-1","call_id":"call-write","name":"write_file","arguments":"{\"path\":\"notes.txt\",\"contents\":\"first line\\nsecond line\\n\"}"}]}}
  > JSONL
  $ start_fake_openai block.jsonl capture-block port-block
  $ spice run --cwd "$PWD" --id blocked-detail "write notes.txt" >block.out 2>&1; echo exit:$?
  exit:3
  $ sed -E "s/perm:[^ ']+/perm:\$ID/g; s/turn=turn_[^ ]+/turn=turn_\$ID/g" block.out
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session blocked-detail waiting: permission perm:$ID tool=write_file turn=turn_$ID call=call-write
  review: default
  accesses:
  - write create $TESTCASE_ROOT/notes.txt  [review: rule a893d6c9785e (user)]
  change:
  - write create $TESTCASE_ROOT/notes.txt (+2 -0)
      --- /dev/null
      +++ $TESTCASE_ROOT/notes.txt
      @@ -0,0 +1,2 @@
      +first line
      +second line
  allow once: spice run reply 'blocked-detail' --allow 'perm:$ID'
  allow conversation: spice run reply 'blocked-detail' --allow-conversation 'perm:$ID'
  deny: spice run reply 'blocked-detail' --deny 'perm:$ID'
  deny with message: spice run reply 'blocked-detail' --deny 'perm:$ID' --message TEXT|-
  $ wait_fake_server

The status JSON exposes the same prompt detail structurally: review behavior,
accesses with explanations, and evidence — enough to render a prompt without
exporting the session.

  $ spice session show --json blocked-detail | grep -o '"review":"default"'
  "review":"default"
  $ spice session show --json blocked-detail | grep -o '"kind":"needs_review_by_rule"'
  "kind":"needs_review_by_rule"
  $ spice session show --json blocked-detail | grep -o '"additions":2'
  "additions":2
  $ spice session show --json blocked-detail | grep -o '"removals":0'
  "removals":0
  $ spice session show --json blocked-detail | grep -c '"diff":'
  1

The JSONL exec stream carries the same fields on permission.requested, and
session.blocked agrees with status on the blocker.

  $ cat > block-json.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-2","call_id":"call-write-json","name":"write_file","arguments":"{\"path\":\"notes.txt\",\"contents\":\"first line\\nsecond line\\n\"}"}]}}
  > JSONL
  $ start_fake_openai block-json.jsonl capture-json port-json
  $ spice run --cwd "$PWD" --json --id blocked-json "write notes.txt" >events.jsonl 2>err.txt; echo exit:$?
  exit:3
  $ grep '"type":"permission.requested"' events.jsonl | grep -o '"review":"default"'
  "review":"default"
  $ grep '"type":"permission.requested"' events.jsonl | grep -o '"explanation":{"kind":"needs_review_by_rule"[^}]*}'
  "explanation":{"kind":"needs_review_by_rule","rule_id":"a893d6c9785e","rule_source":"user"}
  $ grep '"type":"permission.requested"' events.jsonl | grep -o '"additions":2'
  "additions":2
  "additions":2
  $ grep '"type":"session.waiting"' events.jsonl | grep -o '"review":"default"'
  "review":"default"
  $ wait_fake_server

Unattended runs never park: a needed review is denied with stable
model-visible feedback and distinct audit provenance, and the run completes
with exit 0.

  $ cat > unattended.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-3","call_id":"call-write-un","name":"write_file","arguments":"{\"path\":\"secret.txt\",\"contents\":\"data\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","Permission denied: unattended run."]},"response":{"id":"resp-4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"could not write the file"}]}]}}
  > JSONL
  $ start_fake_openai unattended.jsonl capture-un port-un
  $ spice run --cwd "$PWD" --permission-unattended deny --id unattended-run "write secret.txt" 2>/dev/null; echo exit:$?
  could not write the file
  exit:0
  $ wait_fake_server
  $ test -e secret.txt || echo not-written
  not-written

The durable resolution records the unattended provenance, distinct from a
reviewer denial.

  $ spice session export unattended-run | grep -o '"via":"unattended"'
  "via":"unattended"
  $ spice session export unattended-run | grep -o '"answer":"deny"'
  "answer":"deny"

Write confinement does not authorize model-authored host reads. A shell routed
through an enforcing workspace-write sandbox still waits for review, and the
process cannot start before that decision.

  $ outside=$(mktemp -d)
  $ printf 'host secret\n' > "$outside/secret"
  $ cat > shell-read.jsonl <<JSONL
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-shell-read","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-shell-read","call_id":"call-shell-read","name":"shell","arguments":"{\"command\":\"printf started > shell-started; cat $outside/secret\"}"}]}}
  > JSONL
  $ start_fake_openai shell-read.jsonl capture-shell-read port-shell-read
  $ spice run --cwd "$PWD" --sandbox workspace-write --id shell-read "read a host file" >/dev/null 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server
  $ test ! -e shell-started && echo process-not-started
  process-not-started
  $ spice session show --json shell-read | grep -o '"kind":"needs_review"'
  "kind":"needs_review"
  $ rm -r "$outside"

The JSONL stream shows the same provenance on permission.resolved, and the
unattended denial can never allow: the denied tool did not run.

  $ cat > unattended-json.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-5","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-5","call_id":"call-write-un2","name":"write_file","arguments":"{\"path\":\"secret2.txt\",\"contents\":\"data\"}"}]}}
  > {"expect":{"body_contains":["function_call_output"]},"response":{"id":"resp-6","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"stopped"}]}]}}
  > JSONL
  $ start_fake_openai unattended-json.jsonl capture-un2 port-un2
  $ spice run --cwd "$PWD" --json --permission-unattended deny --id unattended-json "write secret2.txt" >un-events.jsonl 2>/dev/null; echo exit:$?
  exit:0
  $ grep '"type":"permission.resolved"' un-events.jsonl | grep -o '"via":"unattended"'
  "via":"unattended"
  "via":"unattended"
  $ grep -c '"type":"turn.finished"' un-events.jsonl
  1
  $ wait_fake_server

A reviewer denial keeps reviewer provenance; the two are never conflated.

  $ cat > reviewer.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-7","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-7","call_id":"call-write-rev","name":"write_file","arguments":"{\"path\":\"reviewed.txt\",\"contents\":\"data\"}"}]}}
  > JSONL
  $ start_fake_openai reviewer.jsonl capture-rev port-rev
  $ spice run --cwd "$PWD" --id reviewer-deny "write reviewed.txt" >/dev/null 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server
  $ permission_id=$(spice session show --json reviewer-deny | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > reviewer-finish.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","not allowed"]},"response":{"id":"resp-8","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"understood"}]}]}}
  > JSONL
  $ start_fake_openai reviewer-finish.jsonl capture-rev2 port-rev2
  $ spice run reply reviewer-deny --cwd "$PWD" --deny "$permission_id" --message "not allowed" >/dev/null 2>&1; echo exit:$?
  exit:0
  $ wait_fake_server
  $ spice session export reviewer-deny | grep -o '"answer":"deny"'
  "answer":"deny"
  $ spice session export reviewer-deny | grep -c '"via":"unattended"'
  0
  [1]

The prompt keeps the reasons captured when it blocked. Adding a durable rule
does not rewrite the audit surface, while resume still rechecks current policy
before it starts the operation.

  $ cat > render.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-9","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-9","call_id":"call-render","name":"write_file","arguments":"{\"path\":\"render.txt\",\"contents\":\"x\"}"}]}}
  > JSONL
  $ start_fake_openai render.jsonl capture-render port-render
  $ spice run --cwd "$PWD" --id render-time "write render.txt" >/dev/null 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server
  $ spice session show render-time | grep '^- '
  - write create $TESTCASE_ROOT/render.txt  [review: rule a893d6c9785e (user)]
  - write create $TESTCASE_ROOT/render.txt (+1 -0)
  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "allow",
  >     "matcher": { "type": "path-exact-relative", "relative": "render.txt" } },
  >   { "action": "review",
  >     "matcher": { "type": "path-workspace", "op": "create" } } ] } }
  > JSON
  $ spice session show render-time | grep '^- '
  - write create $TESTCASE_ROOT/render.txt  [review: rule a893d6c9785e (user)]
  - write create $TESTCASE_ROOT/render.txt (+1 -0)
  $ rm -f "$XDG_CONFIG_HOME/spice/config.json"
