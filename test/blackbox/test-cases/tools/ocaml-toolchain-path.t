Spice inherits the PATH of the process that launched it, so a session started
without the opam switch on PATH must still find the toolchain. Resolution walks
a ladder: the SPICE_DUNE override, PATH, $OPAM_SWITCH_PREFIX/bin, then the
workspace's _opam/bin — and reports the rungs it checked when none resolves,
rather than a bare exec failure.

Capture Spice's absolute path before narrowing PATH, and clear the
toolchain-locator variables this cram run may carry so the fixture controls
them.

  $ SPICE="$(command -v spice)"
  $ unset DUNE_OCAML_STDLIB OPAM_SWITCH_PREFIX SPICE_DUNE

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

Local switch: no locator variables, but the workspace holds an opam local
switch whose _opam/bin resolves dune.

  $ mkdir -p fixture/_opam/bin
  $ cp switch/bin/dune fixture/_opam/bin/dune
  $ start_fake_openai describe.jsonl cap-c port-c
  $ PATH=/usr/bin:/bin "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id local-switch "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "OCaml Dune project" cap-c/request-2.json | head -1
  OCaml Dune project
  $ rm -rf fixture/_opam

Explicit override: SPICE_DUNE names the stub, which is used although PATH
cannot resolve dune.

  $ start_fake_openai describe.jsonl cap-d port-d
  $ PATH=/usr/bin:/bin SPICE_DUNE="$PWD/switch/bin/dune" "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id explicit "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "OCaml Dune project" cap-d/request-2.json | head -1
  OCaml Dune project

A broken override fails loudly and never falls through, even though the real
dune is on this PATH.

  $ start_fake_openai describe.jsonl cap-e port-e
  $ SPICE_DUNE=/no/such/dune "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id broken-override "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "SPICE_DUNE is set to /no/such/dune" cap-e/request-2.json | head -1
  SPICE_DUNE is set to /no/such/dune

The shell tool walks the same ladder: its inner shell resolves dune from the
recovered switch bin.

  $ mkdir -p swshell/bin
  $ cat > swshell/bin/dune <<'EOF'
  > #!/bin/sh
  > echo dune-from-swshell
  > EOF
  $ chmod +x swshell/bin/dune

  $ cat > shell.jsonl <<'JSONL'
  > {"expect":{"body_contains":["go","\"name\":\"shell\""]},"response":{"id":"s1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"is1","call_id":"call-s1","name":"shell","arguments":"{\"command\":\"dune build\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-s1"]},"response":{"id":"s2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL

  $ start_fake_openai shell.jsonl cap-f port-f
  $ PATH=/usr/bin:/bin OPAM_SWITCH_PREFIX="$PWD/swshell" "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id shell-recovered "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "dune-from-swshell" cap-f/request-2.json | head -1
  dune-from-swshell

A dune the shell cannot resolve exits 127 and the failure carries the
toolchain hint, not just the bare shell error.

  $ start_fake_openai shell.jsonl cap-g port-g
  $ PATH=/usr/bin:/bin "$SPICE" run --cwd fixture --permission-mode bypass --sandbox danger-full-access --id shell-unreachable "go" >/dev/null 2>&1
  $ wait_fake_server
  $ grep -oE "dune is not on Spice's PATH" cap-g/request-2.json | head -1
  dune is not on Spice's PATH
