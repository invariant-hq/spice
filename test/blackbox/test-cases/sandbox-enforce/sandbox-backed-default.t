Under an enforcing workspace-write sandbox, the default permission preset runs
workspace edits and sandbox-confined commands without review: the sandbox bounds
their blast radius, so prompting for them would add friction without safety.
Running without confinement still reviews the same operations.

The GPT family ships apply_patch rather than write_file, so pin the
string-replace editor family to keep write_file in the catalog.

  $ unset SPICE_SANDBOX_MODE
  $ git init -q . 2>/dev/null
  $ spice config set tools.editor string-replace

A default-preset run edits a file with a native edit tool and runs a shell
command, and completes with no permission wait under real Seatbelt enforcement.

  $ cat > backed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["backed prompt","\"name\":\"shell\""]},"response":{"id":"resp-backed-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b1","call_id":"call-s1","name":"shell","arguments":"{\"command\":\"echo ok > inside.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-s1","exited 0"]},"response":{"id":"resp-backed-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b2","call_id":"call-w1","name":"write_file","arguments":"{\"path\":\"approved.txt\",\"contents\":\"approved contents\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-w1","created"]},"response":{"id":"resp-backed-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"backed final"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai backed.jsonl backed-capture backed-port
  $ spice run --cwd "$PWD" --json --id backed-run "backed prompt" | grep -o '"outcome":"completed"'
  spice: session saved; resume with: spice resume 'backed-run'
  "outcome":"completed"
  $ wait_fake_server

Both effects landed and no permission was requested.

  $ cat inside.txt
  ok
  $ cat approved.txt
  approved contents
  $ spice session export backed-run | grep -o '"type":"permission_requested"' || echo no-permission-requested
  no-permission-requested

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
