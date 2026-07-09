Shell sandbox modes follow the codex vocabulary. Restricted modes are
requirements: they fail closed when no backend can enforce them, and
danger-full-access runs commands without confinement. The suite default
posture comes from the setup script (SPICE_SANDBOX_MODE=danger-full-access);
these cases override it per invocation.

  $ cat > sandbox-run.jsonl <<'JSONL'
  > {"expect":{"body_contains":["sandbox prompt","\"name\":\"shell\""]},"response":{"id":"resp-sandbox-1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":5,"output_tokens":2},"output":[{"type":"function_call","id":"item-sandbox","call_id":"call-sandbox","name":"shell","arguments":"{\"command\":\"printf sandbox-ok\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-sandbox","sandbox-ok","exited 0"]},"response":{"id":"resp-sandbox-2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":9,"output_tokens":3},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"sandbox final"}]}]}}
  > JSONL

  $ start_fake_openai sandbox-run.jsonl sandbox-capture sandbox-port
  $ spice run --cwd "$PWD" --json --permission-mode bypass --sandbox danger-full-access --id sandbox-live "sandbox prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$TIME/g' | grep '"type":"turn.finished"'
  spice: session saved; resume with: spice resume 'sandbox-live'
  {"schema_version":1,"type":"turn.finished","session_id":"sandbox-live","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"sandbox final","metrics":{"usage":{"input":14,"output":5,"reasoning":0,"cache_read":0,"cache_write":0},"responses":2,"turns":1,"tool_calls":1,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[{"name":"shell","count":1}],"permission_denials":0},"duration_ms":$TIME}
  $ wait_fake_server

An unknown sandbox mode is a usage error.

  $ spice run --cwd "$PWD" --sandbox full-power "nope" >err 2>&1; echo "status:$?"; sed -n '1p; s/.*invalid.*/invalid-sandbox/p; s/.*workspace-write.*/sandbox-values/p' err | uniq
  status:124
  Usage: spice run [--help] [COMMAND] …
  invalid-sandbox
  sandbox-values

A workspace with no chosen mode defaults to workspace-write and fails closed
before provider credentials and before any session exists when no backend can
enforce it. No permission-only degraded default.

  $ unset SPICE_SANDBOX_MODE
  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 spice run --cwd "$PWD" "nope"
  spice: sandbox unavailable: workspace-write requested, sandbox backend forced unavailable (_SPICE_TEST_SANDBOX_UNAVAILABLE=1)
  next: run `spice sandbox status`, choose `--sandbox danger-full-access`, or declare `external-sandbox`
  [1]
  $ spice session list
  ID            PHASE  AGE       TITLE
  sandbox-live  idle   just now  sandbox prompt

A declared external sandbox does not satisfy the default enforcement
requirement; the message names the config that accepts it.

  $ spice run --cwd "$PWD" --sandbox external-sandbox "nope"
  spice: sandbox unavailable: a declared external sandbox does not satisfy sandbox.require=enforced
  next: set sandbox.require=enforced-or-external to accept the declared boundary, or choose an enforceable mode
  [1]

With sandbox.require=enforced-or-external, the declared external boundary is
accepted and shell results carry declared_external evidence.

  $ cat > external-run.jsonl <<'JSONL'
  > {"expect":{"body_contains":["external prompt","\"name\":\"shell\""]},"response":{"id":"resp-external-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-external","call_id":"call-external","name":"shell","arguments":"{\"command\":\"printf external-ok\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-external","declared_external","external-ok"]},"response":{"id":"resp-external-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"external final"}]}]}}
  > JSONL
  $ start_fake_openai external-run.jsonl external-capture external-port
  $ SPICE_SANDBOX_REQUIRE=enforced-or-external spice run --cwd "$PWD" --json --permission-mode bypass --sandbox external-sandbox --id external-run "external prompt" | sed -n '/"type":"run.started"/p; s/.*\("sandbox":{"kind":"declared_external"}\).*/\1/p; s/.*\("final_text":"external final"\).*/\1/p'
  spice: session saved; resume with: spice resume 'external-run'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"external-sandbox","origin":"flag","require":"enforced-or-external","network":"external","backend":"external","enforcement":"declared"}}
  "sandbox":{"kind":"declared_external"}
  "final_text":"external final"
  $ wait_fake_server

An unavailable backend fails restricted runs upfront. The
private test seam forces the unavailable state deterministically on every
platform.

  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 spice run --cwd "$PWD" --sandbox workspace-write "nope"
  spice: sandbox unavailable: workspace-write requested, sandbox backend forced unavailable (_SPICE_TEST_SANDBOX_UNAVAILABLE=1)
  next: run `spice sandbox status`, choose `--sandbox danger-full-access`, or declare `external-sandbox`
  [1]

With sandbox.require=off the run starts and every restricted command is
refused per command instead; enforcement evidence says refused and the
command is never spawned.

  $ cat > refused.jsonl <<'JSONL'
  > {"expect":{"body_contains":["refused prompt","\"name\":\"shell\""]},"response":{"id":"resp-refused-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-refused","call_id":"call-refused","name":"shell","arguments":"{\"command\":\"printf refused-spawn-marker\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-refused","refused"],"body_not_contains":["refused-spawn-marker\\nstderr","refused-spawn-markerstderr"]},"response":{"id":"resp-refused-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"refused final"}]}]}}
  > JSONL
  $ start_fake_openai refused.jsonl refused-capture refused-port
  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 SPICE_SANDBOX_REQUIRE=off SPICE_TRUSTED_WORKSPACE="$PWD" spice run --cwd "$PWD" --json --permission-mode bypass --sandbox workspace-write --id refused-run "refused prompt" | grep -oE '"final_text":"refused final"|"sandbox":\{"kind":"refused"'
  spice: session saved; resume with: spice resume 'refused-run'
  "sandbox":{"kind":"refused"
  "final_text":"refused final"
  $ wait_fake_server

The refusal is machine-readable in the shell tool event itself, no text
parsing required.

Read-only runs advertise only read tools plus shell, and an unavailable
backend refuses ordinary shell commands per call rather than spawning them
unconfined.

  $ cat > read-only-run.jsonl <<'JSONL'
  > {"expect":{"body_contains":["read-only prompt","\"name\":\"read_file\"","\"name\":\"shell\""],"body_not_contains":["\"name\":\"write_file\"","\"name\":\"edit_file\"","\"name\":\"apply_patch\""]},"response":{"id":"resp-ro-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ro","call_id":"call-ro","name":"shell","arguments":"{\"command\":\"printf read-only-spawn-marker\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-ro","refused"],"body_not_contains":["read-only-spawn-marker\\nstderr","read-only-spawn-markerstderr"]},"response":{"id":"resp-ro-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"read-only final"}]}]}}
  > JSONL
  $ start_fake_openai read-only-run.jsonl read-only-capture read-only-port
  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 SPICE_SANDBOX_REQUIRE=off spice run --cwd "$PWD" --json --permission-mode bypass --sandbox read-only --id read-only-run "read-only prompt" | sed -n '/"type":"run.started"/p; s/.*\("sandbox":{"kind":"refused"\).*/\1/p; s/.*\("final_text":"read-only final"\).*/\1/p'
  spice: session saved; resume with: spice resume 'read-only-run'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"read-only","origin":"flag","require":"off","network":"restricted","backend":"none","enforcement":"refused"}}
  "sandbox":{"kind":"refused"
  "final_text":"read-only final"
  $ wait_fake_server

Escalation is refused in read-only runs without spawning and without a
permission flow: the mode's no-mutation promise has no approval-shaped
exception.

  $ cat > escalate-ro.jsonl <<'JSONL'
  > {"expect":{"body_contains":["escalate prompt","\"escalate\"","\"name\":\"read_file\"","\"name\":\"shell\""],"body_not_contains":["\"name\":\"write_file\"","\"name\":\"edit_file\"","\"name\":\"apply_patch\""]},"response":{"id":"resp-esc-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-esc","call_id":"call-esc","name":"shell","arguments":"{\"command\":\"printf never\",\"escalate\":true}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-esc","escalation is not available in a read-only sandbox"]},"response":{"id":"resp-esc-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"escalate final"}]}]}}
  > JSONL
  $ start_fake_openai escalate-ro.jsonl escalate-capture escalate-port
  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 SPICE_SANDBOX_REQUIRE=off spice run --cwd "$PWD" --json --permission-mode bypass --sandbox read-only --id escalate-ro "escalate prompt" | grep -o '"final_text":"escalate final"'
  spice: session saved; resume with: spice resume 'escalate-ro'
  "final_text":"escalate final"
  $ wait_fake_server

sandbox status reports posture as data without provider credentials. The
seam pins the backend; the platform line is host-dependent and normalized.

  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 SPICE_SANDBOX_MODE=workspace-write spice sandbox status --cwd "$PWD" | sed -E 's/platform=[a-z]+ supported=(true|false)/platform=HOST/'
  mode=workspace-write
  origin=config
  require=enforced
  platform=HOST
  backend=none available=false
  restricted=false

  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 SPICE_SANDBOX_MODE=workspace-write spice sandbox status --json --cwd "$PWD" | sed -E 's/"platform":\{"id":"[a-z]+","supported":(true|false)\}/"platform":$PLATFORM/'
  {"schema_version":1,"type":"sandbox_status","mode":"workspace-write","origin":"config","require":"enforced","platform":$PLATFORM,"backend":{"id":"none","available":false,"enforcement":"refused"},"restricted_modes_available":false,"diagnostics":["sandbox backend forced unavailable (_SPICE_TEST_SANDBOX_UNAVAILABLE=1)"]}

sandbox explain reports the policy a run would apply, including protected
metadata and environment stripping facts, without secret values.

  $ _SPICE_TEST_SANDBOX_UNAVAILABLE=1 SPICE_SANDBOX_MODE=workspace-write FAKE_PROVIDER_TOKEN=tok-value spice sandbox explain --cwd "$PWD" | sed -E 's/^writable=.*/writable=$ROOTS/; s/^backend=.*/backend=$BACKEND/; s/environment=inherited [0-9]+, stripped [0-9]+/environment=inherited $N, stripped $M/'
  workspace=.
  mode=workspace-write (config)
  require=enforced
  backend=$BACKEND
  network=restricted
  readable=.
  writable=$ROOTS
  protected=.git,.spice,./.spice,./xdg-config/spice
  environment=inherited $N, stripped $M
  origin sandbox.mode=env SPICE_SANDBOX_MODE

Spice's own config home is among the protected paths (the cram fixture
places it inside the workspace, where workspace-write would otherwise make
it writable). Stripped environment values never appear in explain output,
only counts and patterns.

  $ SPICE_SANDBOX_MODE=workspace-write FAKE_PROVIDER_TOKEN=tok-value spice sandbox explain --cwd "$PWD" | grep tok-value
  [1]
  $ SPICE_SANDBOX_MODE=workspace-write FAKE_PROVIDER_TOKEN=tok-value spice sandbox explain --json --cwd "$PWD" | grep tok-value
  [1]

Sandbox config keys parse strictly and never mutate on failure.

  $ spice config set sandbox.mode full-power 2>&1 | head -2
  spice: unknown sandbox mode: full-power
  Hint: expected one of: read-only, workspace-write, danger-full-access, external-sandbox
  [2]
  $ spice config get sandbox.mode
  spice: sandbox.mode is not set
  [1]
  $ spice config set sandbox.require sometimes 2>&1 | head -1
  spice: unknown sandbox requirement: sometimes
  [2]
