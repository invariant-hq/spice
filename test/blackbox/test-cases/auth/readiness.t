Checked readiness is ephemeral: `--refresh` validates against the provider's
model-list endpoint and reports the result, but nothing is persisted — the
provider is the only authority on validity, so passive status always shows
presence only. Phases drive exit codes: ready and unchecked routes exit 0,
missing and blocked routes exit 1, degraded routes exit 0 because their
problems self-heal.

  $ export OPENAI_API_KEY=sk-test-abcd1234
  $ export SPICE_MODEL=openai/gpt-5.5

A successful refresh reports ready with the account's visible models.

  $ cat > script-ok.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":200,"json":{"data":[{"id":"gpt-5.5"},{"id":"gpt-5.4"}]}}}
  > JSONL
  $ start_fake_server script-ok.jsonl capture-ok port-ok
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-ok)/v1"
  $ spice auth status openai --refresh --json | sed -E 's/"checked_at":[0-9]+/"checked_at":TS/g'
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"env","source_name":"OPENAI_API_KEY","fingerprint":"1234","env":["OPENAI_API_KEY"],"store_names":[],"phase":"ready","checked_at":TS,"problems":[],"transient":false,"repair":null,"selected_model":{"selector":"openai/gpt-5.5","available":true}}]}
  $ wait_fake_server

The check result is this command's to report: passive status afterwards is
unchecked, never a cached claim.

  $ spice auth status openai
  auth_store_path: $TESTCASE_ROOT/xdg-config/spice/auth.json
  storage_backend: file
  PROVIDER  ROUTE    SOURCE              KEY    PHASE      CHECKED  ENV             STORE_NAMES
  openai    api-key  env:OPENAI_API_KEY  …1234  unchecked  -        OPENAI_API_KEY  -
  Hint: run `spice auth status openai --refresh`

A fatal provider rejection reports blocked and exits 1, for this command
only.

  $ cat > script-401.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":401,"json":{"error":{"message":"bad key"}}}}
  > JSONL
  $ start_fake_server script-401.jsonl capture-401 port-401
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-401)/v1"
  $ spice auth status openai --refresh | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TS/'
  auth_store_path: $TESTCASE_ROOT/xdg-config/spice/auth.json
  storage_backend: file
  PROVIDER  ROUTE    SOURCE              KEY    PHASE    CHECKED               ENV             STORE_NAMES
  openai    api-key  env:OPENAI_API_KEY  …1234  blocked  TS  OPENAI_API_KEY  -
  Hint: run `spice auth login openai`
  [1]
  $ wait_fake_server
  $ spice auth status openai --json | grep -o '"phase":"[a-z]*"'
  "phase":"unchecked"

A quota rejection degrades instead of blocking, and a plain rate limit is
transient: both exit 0 because the problems self-heal.

  $ cat > script-quota.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":429,"json":{"error":{"code":"insufficient_quota"}}}}
  > JSONL
  $ start_fake_server script-quota.jsonl capture-quota port-quota
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-quota)/v1"
  $ spice auth status openai --refresh --json | grep -o '"phase":"degraded".*"problems":\["quota_exceeded"\],"transient":false' | sed -E 's/"checked_at":[0-9]+/"checked_at":TS/'
  "phase":"degraded","checked_at":TS,"problems":["quota_exceeded"],"transient":false
  $ wait_fake_server

  $ cat > script-rate.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":429,"json":{"error":{"message":"slow down"}}}}
  > JSONL
  $ start_fake_server script-rate.jsonl capture-rate port-rate
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-rate)/v1"
  $ spice auth status openai --refresh --json | grep -o '"problems":\["rate_limited"\],"transient":true'
  "problems":["rate_limited"],"transient":true
  $ wait_fake_server

Model entitlement is a fact, not a problem: a ready route whose account does
not list the selected model stays ready and reports availability false.

  $ cat > script-other-models.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":200,"json":{"data":[{"id":"gpt-5.4"}]}}}
  > JSONL
  $ start_fake_server script-other-models.jsonl capture-other port-other
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-other)/v1"
  $ spice auth status openai --refresh --json | grep -o '"selected_model":.*'
  "selected_model":{"selector":"openai/gpt-5.5","available":false}}]}
  $ wait_fake_server
  $ unset SPICE_OPENAI_BASE_URL

The all-provider view is inspection: it always exits 0, even when routes are
missing, and names the selected route in its summary.

  $ unset OPENAI_API_KEY
  $ spice auth status --json | grep -o '"summary":.*'
  "summary":{"selected_route":{"provider":"openai","model":"openai/gpt-5.5","phase":"missing"}}}
  $ spice auth status --json >/dev/null
