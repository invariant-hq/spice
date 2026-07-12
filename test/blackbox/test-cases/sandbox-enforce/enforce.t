Real Seatbelt enforcement on macOS: an unset sandbox mode defaults to
workspace-write, where workspace writes succeed, writes outside the
workspace and to protected .git are denied by the OS sandbox, and temp
files work. Evidence on every command names the backend.

  $ unset SPICE_SANDBOX_MODE
  $ export SPICE_SANDBOX_READ=project
  $ unset CAML_LD_LIBRARY_PATH OCAMLLIB OCAMLPATH OCAML_TOPLEVEL_PATH OPAM_SWITCH_PREFIX DUNE_OCAML_STDLIB
  $ git init -q . 2>/dev/null
  $ echo outside-secret > ../seatbelt-secret

  $ cat > enforce.jsonl <<'JSONL'
  > {"expect":{"body_contains":["enforce prompt","\"name\":\"shell\""]},"response":{"id":"resp-enforce-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-e1","call_id":"call-e1","name":"shell","arguments":"{\"command\":\"echo ok > inside.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-e1","exited 0","enforced backend=macos-seatbelt"]},"response":{"id":"resp-enforce-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-e2","call_id":"call-e2","name":"shell","arguments":"{\"command\":\"cat ../seatbelt-secret >/dev/null 2>&1; read_exit=$?; touch ../seatbelt-denied-outside 2>/dev/null; write_exit=$?; echo read-exit=$read_exit write-exit=$write_exit\"}"}]}}
  > {"expect":{"body_contains":["call-e2","read-exit=1","write-exit=1","exited 0"]},"response":{"id":"resp-enforce-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-e3","call_id":"call-e3","name":"shell","arguments":"{\"command\":\"git add inside.txt 2>/dev/null\"}"}]}}
  > {"expect":{"body_contains":["call-e3","exited 128"]},"response":{"id":"resp-enforce-4","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-e4","call_id":"call-e4","name":"shell","arguments":"{\"command\":\"mktemp -t seatbelt > /dev/null && echo tmp-ok\"}"}]}}
  > {"expect":{"body_contains":["call-e4","tmp-ok","exited 0"]},"response":{"id":"resp-enforce-5","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-e5","call_id":"call-e5","name":"shell","arguments":"{\"command\":\"curl -sI --max-time 3 https://www.apple.com >/dev/null 2>&1; echo curl-exit=$?\"}"}]}}
  > {"expect":{"body_contains":["call-e5","curl-exit="],"body_not_contains":["curl-exit=0"]},"response":{"id":"resp-enforce-6","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"enforce final"}]}]}}
  > JSONL

  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai enforce.jsonl enforce-capture enforce-port
  $ SPICE_TRUSTED_WORKSPACE="$PWD" spice run --cwd "$PWD" --json --permission bypass --id enforce-run "enforce prompt" | grep -oE '"outcome":"completed"|"sandbox":\{"mode":"workspace-write","read":"project","origin":"default","require":"enforced","network":"restricted","backend":"macos-seatbelt","enforcement":"enforceable"\}|"sandbox":\{"kind":"enforced","backend":"macos-seatbelt"'
  spice: session saved; resume with: spice resume 'enforce-run'
  "sandbox":{"mode":"workspace-write","read":"project","origin":"default","require":"enforced","network":"restricted","backend":"macos-seatbelt","enforcement":"enforceable"}
  "sandbox":{"kind":"enforced","backend":"macos-seatbelt"
  "sandbox":{"kind":"enforced","backend":"macos-seatbelt"
  "sandbox":{"kind":"enforced","backend":"macos-seatbelt"
  "sandbox":{"kind":"enforced","backend":"macos-seatbelt"
  "sandbox":{"kind":"enforced","backend":"macos-seatbelt"
  "outcome":"completed"
  $ wait_fake_server

Every enforced command's tool event carries machine-readable evidence naming
the backend.

The workspace write landed; the outside write did not.

  $ cat inside.txt
  ok
  $ test -e ../seatbelt-denied-outside || echo denied
  denied

An approved escalation runs that one command unconfined: under bypass the
escalation access is auto-allowed, the previously denied .git write
succeeds, and evidence records not_requested.

  $ cat > escalate.jsonl <<'JSONL'
  > {"expect":{"body_contains":["escalate prompt"]},"response":{"id":"resp-esc-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-x1","call_id":"call-x1","name":"shell","arguments":"{\"command\":\"git add inside.txt\",\"escalate\":true,\"description\":\"commit blocked by sandbox .git protection\"}"}]}}
  > {"expect":{"body_contains":["call-x1","exited 0","not_requested"]},"response":{"id":"resp-esc-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"escalate final"}]}]}}
  > JSONL
  $ start_fake_openai escalate.jsonl escalate-capture escalate-port
  $ SPICE_TRUSTED_WORKSPACE="$PWD" spice run --cwd "$PWD" --json --permission bypass --id escalate-run "escalate prompt" | grep -o '"final_text":"escalate final"'
  spice: session saved; resume with: spice resume 'escalate-run'
  "final_text":"escalate final"
  $ wait_fake_server
  $ git diff --cached --name-only
  inside.txt
