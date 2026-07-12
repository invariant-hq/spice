OCaml Dune tools are part of the model-visible build catalog.

  $ mkdir -p fixture/lib fixture/test
  $ cat > fixture/dune-project <<'EOF'
  > (lang dune 3.0)
  > (name fixture)
  > EOF
  $ cat > fixture/lib/dune <<'EOF'
  > (library (name fixture_lib))
  > EOF
  $ cat > fixture/lib/fixture_lib.ml <<'EOF'
  > let answer = 42
  > EOF
  $ cat > fixture/test/dune <<'EOF'
  > (test (name fixture_test))
  > EOF
  $ cat > fixture/test/fixture_test.ml <<'EOF'
  > let () = assert (Fixture_lib.answer = 42)
  > EOF

The catalog exposes one tool for project shape and one for live Dune RPC
diagnostics.

  $ spice debug tools --cwd fixture | grep '^## ocaml_dune'
  ## ocaml_dune_describe
  ## ocaml_dune_diagnostics

The execution tests disable proactive notices individually. The explicit OCaml
Dune tools remain available; only background prompt-injection producers are
turned off to keep the blackbox run deterministic.

  $ spice config set notices.fswatch false
  $ spice config set notices.cr_comments false
  $ spice config set notices.dune_diagnostics false
  $ spice config set notices.dune_build false

The describe tool runs `dune describe` and returns normalized project evidence
to the model.

  $ cat > describe.jsonl <<'JSONL'
  > {"expect":{"body_contains":["describe the dune project","\"name\":\"ocaml_dune_describe\"","\"name\":\"ocaml_dune_diagnostics\""]},"response":{"id":"resp-describe-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-describe","call_id":"call-describe","name":"ocaml_dune_describe","arguments":"{}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-describe","fixture_lib"],"body_not_contains":["path is outside workspace"]},"response":{"id":"resp-describe-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"describe final"}]}]}}
  > JSONL
  $ start_fake_openai describe.jsonl describe-capture describe-port
  $ spice run --cwd fixture --json --permission bypass --sandbox danger-full-access --id ocaml-dune-describe "describe the dune project" | grep -oE '"tool":"ocaml_dune_describe"|"final_text":"describe final"|"tool_calls_by_name":\[\{"name":"ocaml_dune_describe","count":1\}\]'
  spice: session saved; resume with: spice resume 'ocaml-dune-describe'
  "tool":"ocaml_dune_describe"
  "tool":"ocaml_dune_describe"
  "final_text":"describe final"
  "tool_calls_by_name":[{"name":"ocaml_dune_describe","count":1}]
  $ wait_fake_server

The diagnostics tool uses the shared Dune RPC instance. With Dune build notices
disabled, the tool does not start a background `dune build --watch @all` process
as a side effect; when no RPC server is already registered, it reports the
unavailable tool result and lets the model continue.

  $ cat > diagnostics.jsonl <<'JSONL'
  > {"expect":{"body_contains":["show dune diagnostics","\"name\":\"ocaml_dune_diagnostics\""]},"response":{"id":"resp-diagnostics-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-diagnostics","call_id":"call-diagnostics","name":"ocaml_dune_diagnostics","arguments":"{}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-diagnostics"]},"response":{"id":"resp-diagnostics-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"diagnostics final"}]}]}}
  > JSONL
  $ export SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=10
  $ start_fake_openai diagnostics.jsonl diagnostics-capture diagnostics-port
  $ spice run --cwd fixture --json --permission bypass --sandbox danger-full-access --id ocaml-dune-diagnostics "show dune diagnostics" | grep -oE '"tool":"ocaml_dune_diagnostics"|"final_text":"diagnostics final"|"tool_calls_by_name":\[\{"name":"ocaml_dune_diagnostics","count":1\}\]'
  spice: session saved; resume with: spice resume 'ocaml-dune-diagnostics'
  "tool":"ocaml_dune_diagnostics"
  "tool":"ocaml_dune_diagnostics"
  "final_text":"diagnostics final"
  "tool_calls_by_name":[{"name":"ocaml_dune_diagnostics","count":1}]
  $ wait_fake_server
