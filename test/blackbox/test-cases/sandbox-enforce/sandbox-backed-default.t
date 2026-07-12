Under an enforcing workspace-write sandbox, the default permission behavior
runs native workspace edits without review. It also runs ordinary commands
without review when the sealed boundary restricts reads to the project and
network access. Read-all commands remain reviewable.

The GPT family ships apply_patch rather than write_file, so pin the
string-replace editor family to keep write_file in the catalog.

  $ unset SPICE_SANDBOX_MODE
  $ export SPICE_SANDBOX_READ=all
  $ export SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12
  $ unset CAML_LD_LIBRARY_PATH OCAMLLIB OCAMLPATH OCAML_TOPLEVEL_PATH OPAM_SWITCH_PREFIX DUNE_OCAML_STDLIB
  $ git init -q . 2>/dev/null
  $ spice config set tools.editor string-replace

A read-all run edits a file with a native edit tool, then requests an ordinary
shell command. The edit completes without review; the command parks before
execution because confinement does not bound which host files it can read.

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

With project reads and restricted networking, an ordinary command executes
without a permission event.

  $ cat > project.jsonl <<'JSONL'
  > {"expect":{"body_contains":["project prompt","\"name\":\"shell\""]},"response":{"id":"resp-project-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-p1","call_id":"call-p1","name":"shell","arguments":"{\"command\":\"mkdir -p project-created && printf project > project-created/result.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-p1","exited 0","enforced backend=macos-seatbelt"]},"response":{"id":"resp-project-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"project final"}]}]}}
  > JSONL
  $ start_fake_openai project.jsonl project-capture project-port
  $ SPICE_SANDBOX_READ=project SPICE_TRUSTED_WORKSPACE="$PWD" spice run --cwd "$PWD" --id project-run "project prompt" >project.out 2>&1; echo exit:$?
  exit:0
  $ wait_fake_server
  $ cat project-created/result.txt
  project
  $ if spice session export project-run | grep -q '"type":"permission_requested"'; then echo unexpected-permission; else echo no-permission; fi
  no-permission

A high-impact command remains reviewable even under the automatically credited
project boundary. The run parks on the command access and leaves the file
untouched.

  $ echo keep > victim.txt
  $ cat > destructive.jsonl <<'JSONL'
  > {"expect":{"body_contains":["destructive prompt","\"name\":\"shell\""]},"response":{"id":"resp-destructive-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-d1","call_id":"call-d1","name":"shell","arguments":"{\"command\":\"rm -rf victim.txt\"}"}]}}
  > JSONL
  $ start_fake_openai destructive.jsonl destructive-capture destructive-port
  $ SPICE_SANDBOX_READ=project SPICE_TRUSTED_WORKSPACE="$PWD" spice run --cwd "$PWD" --id destructive-run "destructive prompt" >destructive.out 2>&1; echo exit:$?
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

Read-only with read-all remains reviewable. An explicitly selected external
boundary is automatically credited because the user chose that execution
boundary directly.

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
  > {"expect":{"body_contains":["function_call_output","call-e1","external","declared_external"]},"response":{"id":"resp-external-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"external final"}]}]}}
  > JSONL
  $ start_fake_openai external.jsonl external-capture external-port
  $ spice run --cwd "$PWD" --sandbox external-sandbox --id backed-external "external prompt" >external.out 2>&1; echo exit:$?
  exit:0
  $ wait_fake_server
  $ if spice session export backed-external | grep -q '"type":"permission_requested"'; then echo unexpected-permission; else echo no-permission; fi
  no-permission
