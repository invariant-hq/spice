Live session permission flows are product behavior: the model requests a
workspace mutation, Spice persists a permission wait, and an explicit user
continuation decides whether the tool may run.

The test uses write_file instead of shell because it is the smallest
workspace-local mutating tool. It still exercises the review boundary, durable
continuation, provider-visible feedback, and final session state without
depending on platform shell behavior.

The GPT family ships apply_patch rather than write_file, so pin the
string-replace editor family to keep write_file in the catalog for these flows.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "review",
  >     "matcher": { "type": "path-workspace", "op": "create" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace

  $ cat > allow-start.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.5\"","\"name\":\"write_file\""]},"response":{"id":"resp-allow-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-allow-1","call_id":"call-write-allow","name":"write_file","arguments":"{\"path\":\"approved.txt\",\"contents\":\"approved contents\"}"}]}}
  > JSONL
  $ start_fake_openai allow-start.jsonl allow-capture-start allow-port-start

  $ spice run --cwd "$PWD" --id permission-allow "write approved.txt" >allow-block.out 2>&1; echo exit:$?
  exit:3
  $ sed -E "s/perm:[^ ']+/perm:\$ID/g; s/turn=turn_[^ ]+/turn=turn_\$ID/g" allow-block.out
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session permission-allow waiting: permission perm:$ID tool=write_file turn=turn_$ID call=call-write-allow
  review: default
  accesses:
  - write create $TESTCASE_ROOT/approved.txt  [review: rule a893d6c9785e (user)]
  change:
  - write create $TESTCASE_ROOT/approved.txt (+1 -0)
      --- /dev/null
      +++ $TESTCASE_ROOT/approved.txt
      @@ -0,0 +1,1 @@
      +approved contents
      \ No newline at end of file
  allow once: spice run reply 'permission-allow' --allow 'perm:$ID'
  allow conversation: spice run reply 'permission-allow' --allow-conversation 'perm:$ID'
  deny: spice run reply 'permission-allow' --deny 'perm:$ID'
  deny with message: spice run reply 'permission-allow' --deny 'perm:$ID' --message TEXT|-
  $ wait_fake_server

The waiting session status exposes the live permission request structurally.

  $ spice session show --json permission-allow | grep -o '"phase":"waiting"'
  "phase":"waiting"
  $ spice session show --json permission-allow | grep -o '"kind":"permission"'
  "kind":"permission"
  $ spice session show --json permission-allow | grep -o '"tool":"write_file"'
  "tool":"write_file"
  $ spice session show --json permission-allow | grep -o '"tool_call_id":"call-write-allow"'
  "tool_call_id":"call-write-allow"

The durable export records the permission request before any workspace write.

  $ spice session export permission-allow | grep -o '"type":"permission_requested"'
  "type":"permission_requested"
  $ test -e approved.txt || echo not-written-before-approval
  not-written-before-approval

Allowing the permission resumes the same live turn, executes the pending tool,
and sends the model-visible tool result to the provider.

  $ permission_id=$(spice session show --json permission-allow | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > allow-finish.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-write-allow","approved.txt","created"]},"response":{"id":"resp-allow-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"allowed write finished"}]}]}}
  > JSONL
  $ start_fake_openai allow-finish.jsonl allow-capture-finish allow-port-finish
  $ spice run reply permission-allow --cwd "$PWD" --allow "$permission_id"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool write_file running
  ✓ tool write_file approved.txt completed: A approved.txt
  changed 1 file (+1 -0)
  diff: spice session diff --latest 'permission-allow'
  revert: spice session revert --latest 'permission-allow'
  allowed write finished
  spice: session saved; resume with: spice resume 'permission-allow'
  $ wait_fake_server

  $ cat approved.txt
  approved contents
  $ spice session show --json permission-allow | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"permission-allow","title":null,"preview":"write approved.txt","lifecycle":"active","phase":"idle","forked_from":null,"event_count":8,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":102,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export permission-allow | grep -o '"type":"permission_resolved"'
  "type":"permission_resolved"
  $ spice session export permission-allow | grep -o '"answer":"allow-once"'
  "answer":"allow-once"
  $ spice session export permission-allow | grep -o '"type":"tool_claim_started"'
  "type":"tool_claim_started"
  $ spice session export permission-allow | grep -o '"type":"tool_claim_finished"'
  "type":"tool_claim_finished"
  $ grep -o '"type":"function_call_output"' allow-capture-finish/request-1.json
  "type":"function_call_output"
  $ grep -o '"call_id":"call-write-allow"' allow-capture-finish/request-1.json
  "call_id":"call-write-allow"
  "call_id":"call-write-allow"

Denial is also durable continuation. The denied tool does not execute, but the
model receives an ordinary tool result explaining the denial.

  $ cat > deny-start.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.5\"","\"name\":\"write_file\""]},"response":{"id":"resp-deny-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-deny-1","call_id":"call-write-deny","name":"write_file","arguments":"{\"path\":\"denied.txt\",\"contents\":\"denied contents\"}"}]}}
  > JSONL
  $ start_fake_openai deny-start.jsonl deny-capture-start deny-port-start
  $ spice run --cwd "$PWD" --id permission-deny "write denied.txt" >deny-block.out 2>&1; echo exit:$?
  exit:3
  $ sed -E "s/perm:[^ ']+/perm:\$ID/g; s/turn=turn_[^ ]+/turn=turn_\$ID/g" deny-block.out
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session permission-deny waiting: permission perm:$ID tool=write_file turn=turn_$ID call=call-write-deny
  review: default
  accesses:
  - write create $TESTCASE_ROOT/denied.txt  [review: rule a893d6c9785e (user)]
  change:
  - write create $TESTCASE_ROOT/denied.txt (+1 -0)
      --- /dev/null
      +++ $TESTCASE_ROOT/denied.txt
      @@ -0,0 +1,1 @@
      +denied contents
      \ No newline at end of file
  allow once: spice run reply 'permission-deny' --allow 'perm:$ID'
  allow conversation: spice run reply 'permission-deny' --allow-conversation 'perm:$ID'
  deny: spice run reply 'permission-deny' --deny 'perm:$ID'
  deny with message: spice run reply 'permission-deny' --deny 'perm:$ID' --message TEXT|-
  $ wait_fake_server

  $ deny_permission_id=$(spice session show --json permission-deny | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > deny-finish.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-write-deny","not this time"]},"response":{"id":"resp-deny-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"denied write acknowledged"}]}]}}
  > JSONL
  $ start_fake_openai deny-finish.jsonl deny-capture-finish deny-port-finish
  $ spice run reply permission-deny --cwd "$PWD" --deny "$deny_permission_id" --message "not this time"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  denied write acknowledged
  spice: session saved; resume with: spice resume 'permission-deny'
  $ wait_fake_server

  $ test -e denied.txt || echo denied-file-not-created
  denied-file-not-created
  $ spice session show --json permission-deny | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"permission-deny","title":null,"preview":"write denied.txt","lifecycle":"active","phase":"idle","forked_from":null,"event_count":6,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":79,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export permission-deny | grep -o '"type":"permission_resolved"'
  "type":"permission_resolved"
  $ spice session export permission-deny | grep -o '"answer":"deny"'
  "answer":"deny"
  $ spice session export permission-deny | grep -o '"text":"not this time"'
  "text":"not this time"
  $ spice session export permission-deny | grep -o '"type":"tool_claim_started"' || echo no-tool-execution
  no-tool-execution
  $ grep -o '"type":"function_call_output"' deny-capture-finish/request-1.json
  "type":"function_call_output"
  $ grep -o '"call_id":"call-write-deny"' deny-capture-finish/request-1.json
  "call_id":"call-write-deny"
  "call_id":"call-write-deny"
  $ grep -o 'not this time' deny-capture-finish/request-1.json
  not this time

Denial without explicit feedback records the default model-visible denial
text.

  $ cat > deny-default-start.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.5\"","\"name\":\"write_file\""]},"response":{"id":"resp-deny-default-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-deny-default-1","call_id":"call-write-default","name":"write_file","arguments":"{\"path\":\"default.txt\",\"contents\":\"default contents\"}"}]}}
  > JSONL
  $ start_fake_openai deny-default-start.jsonl deny-default-capture-start deny-default-port-start
  $ spice run --cwd "$PWD" --id permission-deny-default "write default.txt" >deny-default-block.out 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server

  $ default_permission_id=$(spice session show --json permission-deny-default | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > deny-default-finish.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-write-default","Permission denied."]},"response":{"id":"resp-deny-default-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"default denial acknowledged"}]}]}}
  > JSONL
  $ start_fake_openai deny-default-finish.jsonl deny-default-capture-finish deny-default-port-finish
  $ spice run reply permission-deny-default --cwd "$PWD" --deny "$default_permission_id"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  default denial acknowledged
  spice: session saved; resume with: spice resume 'permission-deny-default'
  $ wait_fake_server

  $ test -e default.txt || echo default-file-not-created
  default-file-not-created
  $ spice session export permission-deny-default | grep -o '"text":"Permission denied."'
  "text":"Permission denied."
