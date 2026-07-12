Doctor aggregates local health checks without contacting a provider. With no
credential for the selected model's provider, auth fails and the exit code
says so; everything else is healthy in a fresh workspace.

  $ git init -q .
  $ SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -E 's|^  dune: .*|  dune: $DUNE|'
  config: ok
  storage: ok
    cwd=$TESTCASE_ROOT
    project=$TESTCASE_ROOT
    data=$TESTCASE_ROOT/xdg-data/spice
    state=$TESTCASE_ROOT/xdg-state/spice
  workspace trust: ok
    store=$TESTCASE_ROOT/xdg-config/spice/trust.json
    valid=true
    root=$TESTCASE_ROOT
    status=trusted
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
    mode=danger-full-access read=all origin=config backend=none not_requested network=enabled
  sessions: ok
    0 documents
  project config: ok
    workspace config applied
  [1]

With a credential present, doctor is clean and exits zero.

  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -E 's|^  dune: .*|  dune: $DUNE|'
  config: ok
  storage: ok
    cwd=$TESTCASE_ROOT
    project=$TESTCASE_ROOT
    data=$TESTCASE_ROOT/xdg-data/spice
    state=$TESTCASE_ROOT/xdg-state/spice
  workspace trust: ok
    store=$TESTCASE_ROOT/xdg-config/spice/trust.json
    valid=true
    root=$TESTCASE_ROOT
    status=trusted
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
    mode=danger-full-access read=all origin=config backend=none not_requested network=enabled
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
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor --json | grep -o '"name":"workspace trust","status":"ok"'
  "name":"workspace trust","status":"ok"
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor --json | grep -o '"ok":true'
  "ok":true

Doctor distinguishes an unknown nested project from an explicit untrusted
decision without starting a run.

  $ mkdir -p nested/.git
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor -C nested --json > nested-unknown.json
  $ grep -o '"status=unknown"' nested-unknown.json
  "status=unknown"
  $ spice untrust nested
  untrusted $TESTCASE_ROOT/nested
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor -C nested --json > nested-untrusted.json
  $ grep -o '"status=untrusted"' nested-untrusted.json
  "status=untrusted"

Doctor does not even consider a project-local toolchain before workspace
consent. Once the same canonical root is trusted, the local switch becomes an
eligible diagnostic source.

  $ mkdir -p local-switch/.git local-switch/_opam/bin
  $ printf '#!/bin/sh\nexit 0\n' > local-switch/_opam/bin/dune
  $ chmod +x local-switch/_opam/bin/dune
  $ spice_bin=$(command -v spice)
  $ env -u SPICE_DUNE -u OPAM_SWITCH_PREFIX PATH=/usr/bin:/bin OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 "$spice_bin" doctor -C local-switch > local-unknown.out
  $ grep 'project-local _opam lookup disabled' local-unknown.out
    project-local _opam lookup disabled: workspace trust is unknown
  $ if grep -q 'local-switch/_opam' local-unknown.out; then echo considered; else echo not-considered; fi
  not-considered
  $ env -u SPICE_DUNE -u OPAM_SWITCH_PREFIX PATH=/usr/bin:/bin "$spice_bin" sandbox explain --cwd local-switch > local-sandbox.out
  $ if grep -q 'local-switch/_opam' local-sandbox.out; then echo considered; else echo not-considered; fi
  not-considered
  $ spice trust local-switch >/dev/null
  $ env -u SPICE_DUNE -u OPAM_SWITCH_PREFIX PATH=/usr/bin:/bin OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 "$spice_bin" doctor -C local-switch > local-trusted.out
  $ sed -n '/^ocaml toolchain:/,/^sandbox:/p' local-trusted.out | sed -E 's|dune: .*/local-switch/_opam/bin/dune|dune: $LOCAL_DUNE|'
  ocaml toolchain: ok
    dune: $LOCAL_DUNE (via local _opam switch)
  sandbox: ok

Unknown config fields are a warning, not a failure.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"totally_unknown_field":true}' > "$XDG_CONFIG_HOME/spice/config.json"
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 spice doctor | sed -n '/^config/,/^storage/p'
  config: warn
    $TESTCASE_ROOT/xdg-config/spice/config.json unknown field: totally_unknown_field
  storage: ok
