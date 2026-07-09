Doctor aggregates local health checks without contacting a provider. With no
credential for the selected model's provider, auth fails and the exit code
says so; everything else is healthy in a fresh workspace.

  $ git init -q .
  $ SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -E 's|^  dune: .*|  dune: $DUNE|'
  config: ok
  auth: fail
    openai: missing (selected model provider); run `spice auth login openai`
    anthropic: missing; run `spice auth login anthropic`
    google: missing; run `spice auth login google`
    deepseek: ready
    local: ready
    ollama: ready
  local engine: warn
    spice-test-llama-server was not found on PATH; install llama.cpp (for example: brew install llama.cpp) or configure an explicit server binary
  ocaml toolchain: ok
    dune: $DUNE
  sandbox: ok
    mode=danger-full-access origin=config backend=none not_requested network=enabled
  sessions: ok
    0 documents
  project config: ok
    workspace config applied
  [1]

With a credential present, doctor is clean and exits zero.

  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -E 's|^  dune: .*|  dune: $DUNE|'
  config: ok
  auth: ok
    openai: unchecked (selected model provider); run `spice auth status openai --refresh`
    anthropic: missing; run `spice auth login anthropic`
    google: missing; run `spice auth login google`
    deepseek: ready
    local: ready
    ollama: ready
  local engine: warn
    spice-test-llama-server was not found on PATH; install llama.cpp (for example: brew install llama.cpp) or configure an explicit server binary
  ocaml toolchain: ok
    dune: $DUNE
  sandbox: ok
    mode=danger-full-access origin=config backend=none not_requested network=enabled
  sessions: ok
    0 documents
  project config: ok
    workspace config applied

Corrupt session documents are a warning, reported with their full
diagnostics; warnings do not change the exit code.

  $ spice session create --id good
  good
  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/bad
  $ echo '{broken' > $SPICE_TEST_DATA_HOME/sessions/bad/session.json
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -n '/^sessions/,/^project config/p'
  sessions: warn
    1 document, 1 corrupt
    $TESTCASE_ROOT/xdg-data/spice/sessions/bad/session.json:
      Expected: object member or } but found b
      File "-", line 1, characters 1-2:
  project config: ok

Listings print one corrupt line each and point here for the full trace.

  $ spice session list >/dev/null
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/bad/session.json: Expected: object member or } but found b; run `spice doctor` for details

The JSON envelope carries the same checks.

  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor --json | grep -o '"type":"doctor"'
  "type":"doctor"
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor --json | grep -o '"name":"sessions","status":"warn"'
  "name":"sessions","status":"warn"
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor --json | grep -o '"ok":true'
  "ok":true

Unknown config fields are a warning, not a failure.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"totally_unknown_field":true}' > "$XDG_CONFIG_HOME/spice/config.json"
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -n '/^config/,/^auth/p'
  config: warn
    $TESTCASE_ROOT/xdg-config/spice/config.json unknown field: totally_unknown_field
  auth: ok
