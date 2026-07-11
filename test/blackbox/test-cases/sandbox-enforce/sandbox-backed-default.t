Under an enforcing workspace-write sandbox, the default permission preset runs
native workspace edits without review because their implementation uses the
workspace boundary. A non-destructive command also runs without review only
when its permission fact proves that its executor uses the sealed sandbox.

The GPT family ships apply_patch rather than write_file, so pin the
string-replace editor family to keep write_file in the catalog.

  $ unset SPICE_SANDBOX_MODE
  $ git init -q . 2>/dev/null
  $ spice config set tools.editor string-replace

A default-preset run edits a file with a native edit tool, then requests an
ordinary shell command. Both complete without review through their proven
runtime boundaries.

  $ cat > backed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["backed prompt","\"name\":\"write_file\""]},"response":{"id":"resp-backed-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b1","call_id":"call-w1","name":"write_file","arguments":"{\"path\":\"approved.txt\",\"contents\":\"approved contents\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-w1","created"]},"response":{"id":"resp-backed-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b2","call_id":"call-s1","name":"shell","arguments":"{\"command\":\"echo ok > inside.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-s1","exited 0"]},"response":{"id":"resp-backed-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"sealed command completed"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai backed.jsonl backed-capture backed-port
  $ spice run --cwd "$PWD" --json --id backed-run "backed prompt" >backed.out 2>&1; echo exit:$?
  exit:0
  $ grep -o 'sealed command completed' backed.out
  sealed command completed
  $ wait_fake_server

The native edit and sealed command landed without a permission event.

  $ cat approved.txt
  approved contents
  $ cat inside.txt
  ok
  $ spice session export backed-run | grep -q '"type":"permission_requested"' || echo no-permission-request
  no-permission-request

A destructive command is still reviewable. The run parks on the earlier
destructive-command rule and leaves the file untouched.

  $ echo keep > victim.txt
  $ cat > destructive.jsonl <<'JSONL'
  > {"expect":{"body_contains":["destructive prompt","\"name\":\"shell\""]},"response":{"id":"resp-destructive-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-d1","call_id":"call-d1","name":"shell","arguments":"{\"command\":\"rm -rf victim.txt\"}"}]}}
  > JSONL
  $ start_fake_openai destructive.jsonl destructive-capture destructive-port
  $ spice run --cwd "$PWD" --id destructive-run "destructive prompt" >destructive.out 2>&1; echo exit:$?
  exit:3
  $ grep -oF "command exec 'rm' '-rf' 'victim.txt'" destructive.out
  command exec 'rm' '-rf' 'victim.txt'
  $ grep -o 'review: rule' destructive.out
  review: rule
  $ wait_fake_server
  $ cat victim.txt
  keep

Without an enforcing sandbox the credit does not apply: the same default preset
still reviews a command, because nothing bounds its blast radius. The run parks
on the review and exits blocked before the command executes.

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

Read-only and externally declared postures likewise contribute no
workspace-write command credit.

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
