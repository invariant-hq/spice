Spice inherits the PATH of the process that launched it, so a session started
without the opam switch on PATH must still find the toolchain: the OCaml tools
recover the switch bin from the variables opam exports, and report a clear cause
when nothing can be recovered rather than a bare exec failure.

Capture Spice's absolute path before narrowing PATH, and clear the
toolchain-locator variables Dune sets for this cram run so the fixture controls
them.

  $ SPICE="$(command -v spice)"
  $ unset DUNE_OCAML_STDLIB OPAM_SWITCH_PREFIX

  $ mkdir -p fixture/lib
  $ cat > fixture/dune-project <<'EOF'
  > (lang dune 3.0)
  > (name fixture)
  > EOF
  $ cat > fixture/lib/dune <<'EOF'
  > (library (name fixture_lib))
  > EOF
  $ echo 'let answer = 42' > fixture/lib/fixture_lib.ml

A fake switch whose bin holds a stub dune that emits an empty describe.

  $ mkdir -p switch/bin
  $ cat > switch/bin/dune <<'EOF'
  > #!/bin/sh
  > echo '()'
  > EOF
  $ chmod +x switch/bin/dune

  $ spice config set notices.fswatch false
  $ spice config set notices.dune_diagnostics false
  $ spice config set notices.dune_build false

  $ cat > describe.jsonl <<'JSONL'
  > {"expect":{"body_contains":["go","ocaml_dune_describe"]},"response":{"id":"r1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"i1","call_id":"call-d","name":"ocaml_dune_describe","arguments":"{}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-d"]},"response":{"id":"r2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL

Unreachable: neither PATH nor a locator resolves dune, so the tool names the
cause. The command runs with a narrowed PATH that excludes the real dune, and
Spice is invoked by its absolute path so it still resolves.

  $ start_fake_openai describe.jsonl cap-a port-a
  $ PATH=/usr/bin:/bin "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id unreachable "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "dune is not on Spice's PATH" cap-a/request-2.json | head -1
  dune is not on Spice's PATH

Recovery: OPAM_SWITCH_PREFIX points at the fake switch, so the stub dune runs and
the tool returns a project shape instead of the hint.

  $ start_fake_openai describe.jsonl cap-b port-b
  $ PATH=/usr/bin:/bin OPAM_SWITCH_PREFIX="$PWD/switch" "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id recovered "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "OCaml Dune project" cap-b/request-2.json | head -1
  OCaml Dune project
  $ grep -c "not on Spice's PATH" cap-b/request-2.json || true
  0
