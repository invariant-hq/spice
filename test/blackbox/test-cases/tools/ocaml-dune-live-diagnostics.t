OCaml Dune diagnostics are useful during iterative development: a clean project
can become broken during a run, the host should keep the shared Dune RPC
connection live, avoid injecting diagnostics Dune has not published, and let the
explicit diagnostics tool return the latest known Dune evidence without
blocking the turn.

  $ fixture="${TMPDIR:-/tmp}/spice-ocaml-dune-live-$$"
  $ rm -rf "$fixture"
  $ mkdir -p "$fixture/lib" "$fixture/test"
  $ cat > "$fixture/dune-project" <<'EOF'
  > (lang dune 3.0)
  > (name fixture)
  > EOF
  $ cat > "$fixture/lib/dune" <<'EOF'
  > (library (name fixture_lib))
  > EOF
  $ cat > "$fixture/lib/fixture_lib.ml" <<'EOF'
  > let answer = 42
  > EOF
  $ cat > "$fixture/test/dune" <<'EOF'
  > (test (name fixture_test))
  > EOF
  $ cat > "$fixture/test/fixture_test.ml" <<'EOF'
  > let () = assert (Fixture_lib.answer = 42)
  > EOF
  $ spice trust "$fixture" > /dev/null

Only the Dune diagnostics notice stream is enabled. This keeps the request body
focused on compiler diagnostics while still using the real host watcher and the
same shared Dune RPC instance as the diagnostics tool.

  $ spice config set notices.fswatch false
  $ spice config set notices.cr_comments false
  $ spice config set notices.dune_build false
  $ spice config set notices.dune_diagnostics true

The fake model first breaks the previously working project by adding an invalid
Dune field. The shell command waits briefly before and after the edit so the
background Dune RPC watch can connect. Dune 3.23 does not publish this
Dune-file parse failure through the diagnostics stream before the next request,
so Spice must not invent a proactive diagnostic notice or block waiting for a
synchronous diagnostics response.

  $ cat > iterative.jsonl <<'JSONL'
  > {"expect":{"body_contains":["break the OCaml project","\"name\":\"shell\"","\"name\":\"ocaml_dune_diagnostics\""],"body_not_contains":["New OCaml diagnostics available","Dune diagnostics unavailable"]},"response":{"id":"resp-iterative-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-break","call_id":"call-break","name":"shell","arguments":"{\"command\":\"sleep 1; printf '(library (name fixture_lib) (unknown_field true))\\\\n' > lib/dune; sleep 4\",\"description\":\"break Dune project after Dune watch starts\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-break"],"body_not_contains":["[spice notice]","New OCaml diagnostics available"]},"response":{"id":"resp-iterative-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-diagnostics","call_id":"call-diagnostics-live","name":"ocaml_dune_diagnostics","arguments":"{}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-diagnostics-live","OCaml Dune diagnostics: none","endpoint:"]},"response":{"id":"resp-iterative-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"diagnostics observed"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai iterative.jsonl iterative-capture iterative-port
  $ spice run --cwd "$fixture" --json --permission bypass --sandbox danger-full-access --id ocaml-dune-iterative "break the OCaml project and inspect diagnostics" | grep -oE '"tool":"shell"|"tool":"ocaml_dune_diagnostics"|"final_text":"diagnostics observed"|"tool_calls_by_name":\[\{"name":"ocaml_dune_diagnostics","count":1\},\{"name":"shell","count":1\}\]'
  spice: session saved; resume with: spice resume 'ocaml-dune-iterative'
  "tool":"shell"
  "tool":"shell"
  "tool":"ocaml_dune_diagnostics"
  "tool":"ocaml_dune_diagnostics"
  "final_text":"diagnostics observed"
  "tool_calls_by_name":[{"name":"ocaml_dune_diagnostics","count":1},{"name":"shell","count":1}]
  $ wait_fake_server

The captured provider requests show that no proactive diagnostic notice is
injected for an unpublished Dune-file parse failure, and that the explicit tool
returns the latest known RPC store instead of hanging.

  $ python3 - <<'PY'
  > import json
  > def strings(value):
  >   if isinstance(value, str):
  >     yield value
  >   elif isinstance(value, list):
  >     for item in value:
  >       yield from strings(item)
  >   elif isinstance(value, dict):
  >     for item in value.values():
  >       yield from strings(item)
  > with open("iterative-capture/request-2.json") as f:
  >   request = json.load(f)
  > notice = any("[spice notice]" in text and "ocaml-dune-diagnostics" in text for text in strings(request))
  > print(f"notice-present: {str(notice).lower()}")
  > PY
  notice-present: false

  $ python3 - <<'PY'
  > import json
  > with open("iterative-capture/request-3.json") as f:
  >   request = json.load(f)
  > for item in request["input"]:
  >   if item.get("type") == "function_call_output" and item.get("call_id") == "call-diagnostics-live":
  >     for line in item["output"].splitlines():
  >       print("endpoint: <endpoint>" if line.startswith("endpoint: ") else line)
  >     break
  > PY
  OCaml Dune diagnostics: none
  endpoint: <endpoint>
