Real Bubblewrap enforcement on Linux: platform backend selection chooses
Bubblewrap by default. Workspace writes succeed, writes outside the workspace
and to protected metadata are denied, temp files work, nonzero command status
and streams are propagated, and restricted network is isolated. Evidence on
every command names the backend.

  $ unset SPICE_SANDBOX_MODE
  $ export SPICE_SANDBOX_READ=project
  $ unset CAML_LD_LIBRARY_PATH OCAMLLIB OCAMLPATH OCAML_TOPLEVEL_PATH OPAM_SWITCH_PREFIX DUNE_OCAML_STDLIB
  $ git init -q . 2>/dev/null
  $ mkdir -p .spice xdg-config/spice

  $ cat > enforce.jsonl <<'JSONL'
  > {"expect":{"body_contains":["enforce prompt","\"name\":\"shell\""]},"response":{"id":"resp-bw-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw1","call_id":"call-bw1","name":"shell","arguments":"{\"command\":\"echo ok > inside.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-bw1","exited 0","enforced backend=linux-bubblewrap"]},"response":{"id":"resp-bw-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw2","call_id":"call-bw2","name":"shell","arguments":"{\"command\":\"touch ../bubblewrap-denied-outside 2>/dev/null\"}"}]}}
  > {"expect":{"body_contains":["call-bw2","exited 1"]},"response":{"id":"resp-bw-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw3","call_id":"call-bw3","name":"shell","arguments":"{\"command\":\"touch .git/bubblewrap-denied 2>/dev/null\"}"}]}}
  > {"expect":{"body_contains":["call-bw3","exited 1"]},"response":{"id":"resp-bw-4","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw4","call_id":"call-bw4","name":"shell","arguments":"{\"command\":\"touch .spice/bubblewrap-denied 2>/dev/null\"}"}]}}
  > {"expect":{"body_contains":["call-bw4","exited 1"]},"response":{"id":"resp-bw-5","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw5","call_id":"call-bw5","name":"shell","arguments":"{\"command\":\"mktemp -t bubblewrap > /dev/null && echo tmp-ok\"}"}]}}
  > {"expect":{"body_contains":["call-bw5","tmp-ok","exited 0"]},"response":{"id":"resp-bw-6","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw6","call_id":"call-bw6","name":"shell","arguments":"{\"command\":\"printf stdout; printf stderr >&2; exit 7\"}"}]}}
  > {"expect":{"body_contains":["call-bw6","stdout","stderr","exited 7"]},"response":{"id":"resp-bw-7","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-bw7","call_id":"call-bw7","name":"shell","arguments":"{\"command\":\"curl -sI --max-time 3 https://www.example.com >/dev/null 2>&1; echo curl-exit=$?\"}"}]}}
  > {"expect":{"body_contains":["call-bw7","curl-exit="],"body_not_contains":["curl-exit=0"]},"response":{"id":"resp-bw-8","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"bubblewrap final"}]}]}}
  > JSONL

  $ start_fake_openai enforce.jsonl bubblewrap-capture bubblewrap-port
  $ spice run --cwd "$PWD" --json --permission bypass --id bubblewrap-run "enforce prompt" | grep -oE '"outcome":"completed"|"sandbox":\{"mode":"workspace-write","read":"project","origin":"default","require":"enforced","network":"restricted","backend":"linux-bubblewrap","enforcement":"enforceable"\}|"sandbox":\{"kind":"enforced","backend":"linux-bubblewrap"'
  spice: session saved; resume with: spice resume 'bubblewrap-run'
  "sandbox":{"mode":"workspace-write","read":"project","origin":"default","require":"enforced","network":"restricted","backend":"linux-bubblewrap","enforcement":"enforceable"}
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "sandbox":{"kind":"enforced","backend":"linux-bubblewrap"
  "outcome":"completed"
  $ wait_fake_server

The workspace write landed; the outside and protected metadata writes did not.

  $ cat inside.txt
  ok
  $ test -e ../bubblewrap-denied-outside || echo denied
  denied
  $ test -e .git/bubblewrap-denied || echo git-denied
  git-denied
  $ test -e .spice/bubblewrap-denied || echo spice-denied
  spice-denied
