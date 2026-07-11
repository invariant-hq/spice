Under an enforcing workspace-write sandbox, the default permission preset runs
native workspace edits without review because their implementation uses the
workspace boundary. Model-authored shell remains reviewable because write
confinement does not authorize the host files that a command can read.

The GPT family ships apply_patch rather than write_file, so pin the
string-replace editor family to keep write_file in the catalog.

  $ unset SPICE_SANDBOX_MODE
  $ git init -q . 2>/dev/null
  $ spice config set tools.editor string-replace

A default-preset run edits a file with a native edit tool, then requests an
ordinary shell command. The edit completes without review; the command parks
before execution even though its eventual route is the sealed sandbox.

  $ cat > backed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["backed prompt","\"name\":\"write_file\""]},"response":{"id":"resp-backed-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b1","call_id":"call-w1","name":"write_file","arguments":"{\"path\":\"approved.txt\",\"contents\":\"approved contents\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-w1","created"]},"response":{"id":"resp-backed-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b2","call_id":"call-s1","name":"shell","arguments":"{\"command\":\"echo ok > inside.txt\"}"}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai backed.jsonl backed-capture backed-port
  $ spice run --cwd "$PWD" --json --id backed-run "backed prompt" >backed.out 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server

The native edit landed, while the command emitted a permission event and did
not start.

  $ cat approved.txt
  approved contents
  $ test -e inside.txt || echo command-not-run-before-approval
  command-not-run-before-approval
  $ spice session export backed-run | grep -o '"type":"permission_requested"'
  "type":"permission_requested"

A destructive command is likewise reviewable. The run parks on the command
access and leaves the file untouched.

  $ echo keep > victim.txt
  $ cat > destructive.jsonl <<'JSONL'
  > {"expect":{"body_contains":["destructive prompt","\"name\":\"shell\""]},"response":{"id":"resp-destructive-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-d1","call_id":"call-d1","name":"shell","arguments":"{\"command\":\"rm -rf victim.txt\"}"}]}}
  > JSONL
  $ start_fake_openai destructive.jsonl destructive-capture destructive-port
  $ spice run --cwd "$PWD" --id destructive-run "destructive prompt" >destructive.out 2>&1; echo exit:$?
  exit:3
  $ grep -oF "command exec 'rm' '-rf' 'victim.txt'" destructive.out
  command exec 'rm' '-rf' 'victim.txt'
  $ grep -o 'waiting: permission' destructive.out
  waiting: permission
  $ wait_fake_server
  $ cat victim.txt
  keep

Without an enforcing sandbox the same default preset also reviews the direct
command. The run parks before execution.

  $ cat > unconfined.jsonl <<'JSONL'
  > {"expect":{"body_contains":["unconfined prompt","\"name\":\"shell\""]},"response":{"id":"resp-unconfined-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-u1","call_id":"call-u1","name":"shell","arguments":"{\"command\":\"echo hi > escaped.txt\"}"}]}}
  > JSONL
  $ start_fake_openai unconfined.jsonl unconfined-capture unconfined-port
  $ spice run --cwd "$PWD" --sandbox danger-full-access --id backed-unconfined "unconfined prompt" >unconfined.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'waiting: permission' unconfined.out
  waiting: permission
  $ wait_fake_server
  $ test -e escaped.txt || echo command-not-run-before-approval
  command-not-run-before-approval

Read-only and externally declared postures follow the same independent
permission boundary.

  $ cat > read-only.jsonl <<'JSONL'
  > {"expect":{"body_contains":["read-only prompt","\"name\":\"shell\""]},"response":{"id":"resp-read-only-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-r1","call_id":"call-r1","name":"shell","arguments":"{\"command\":\"printf read-only\"}"}]}}
  > JSONL
  $ start_fake_openai read-only.jsonl read-only-capture read-only-port
  $ spice run --cwd "$PWD" --sandbox read-only --id backed-read-only "read-only prompt" >read-only.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'waiting: permission' read-only.out
  waiting: permission
  $ wait_fake_server

  $ spice config set sandbox.require enforced-or-external
  $ cat > external.jsonl <<'JSONL'
  > {"expect":{"body_contains":["external prompt","\"name\":\"shell\""]},"response":{"id":"resp-external-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-e1","call_id":"call-e1","name":"shell","arguments":"{\"command\":\"printf external\"}"}]}}
  > JSONL
  $ start_fake_openai external.jsonl external-capture external-port
  $ spice run --cwd "$PWD" --sandbox external-sandbox --id backed-external "external prompt" >external.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'waiting: permission' external.out
  waiting: permission
  $ wait_fake_server
