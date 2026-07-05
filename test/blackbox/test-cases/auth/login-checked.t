Login saves first, then validates, and reports the readiness result for this
command only — nothing is cached. A failed validation is a readiness fact,
not a save failure: the credential stays saved either way. (The TTY refusal
for --api-key-stdin cannot be exercised here — cram tests have no PTY — so
that path is review-only.)

A valid key logs in ready and names the next useful command.

  $ export SPICE_MODEL=openai/gpt-5.5
  $ cat > script-ok.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":200,"json":{"data":[{"id":"gpt-5.5"}]}}}
  > JSONL
  $ start_fake_server script-ok.jsonl capture-ok port-ok
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-ok)/v1"
  $ printf sk-test-abcd1234 | spice auth login openai --method api-key --api-key-stdin | sed -E -e 's#\(file store [^)]+\)#(file store $AUTH)#' -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TS/'
  Logged in to openai with api-key.
  Saved:   default (file store $AUTH)
  Checked: ready (validated TS)
  Next:    spice run --model openai/gpt-5.5 "..."
  $ wait_fake_server

The validation belongs to the login that ran it: passive status afterwards
shows presence only.

  $ spice auth status openai --json | grep -o '"phase":"[a-z]*"'
  "phase":"unchecked"

A rejected key reports blocked, exits 1, and is still saved: rerunning login
with a good key is the repair, not re-entering a lost one.

  $ cat > script-401.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":401,"json":{"error":{"message":"bad key"}}}}
  > JSONL
  $ start_fake_server script-401.jsonl capture-401 port-401
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-401)/v1"
  $ printf sk-test-badbadbad | spice auth login openai --method api-key --api-key-stdin | sed -E 's#\(file store [^)]+\)#(file store $AUTH)#'
  Logged in to openai with api-key.
  Saved:   default (file store $AUTH)
  Checked: blocked (invalid_credential)
  Next:    spice auth status openai
  [1]
  $ wait_fake_server
  $ spice auth names openai
  Usage: spice auth [--help] COMMAND …
  spice: unknown command names. Must be one of login, logout, remove, save or
         status
  [124]
  $ spice auth status openai --json | grep -o '"source":"store"'
  "source":"store"

The secret never appears in login output or status.

  $ spice auth status openai --json | grep -c "sk-test-badbadbad"
  0
  [1]

Save is the deliberately validation-free storage helper: no provider
request is made.

  $ printf sk-test-fresh5678 | spice auth save openai --api-key-stdin
  Saved openai credential default
  $ spice auth status openai --json | grep -o '"phase":"[a-z]*"'
  "phase":"unchecked"
