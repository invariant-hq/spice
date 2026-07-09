An OpenAI OAuth credential selects the ChatGPT route: same Responses API
shape, different backend, account id attached as a header. The provider
base-URL override applies to whichever route the credential selects, which is
what lets these tests point the route at a local fake.

  $ git init -q

  $ export SPICE_MODEL=openai/gpt-5.5
  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"oauth","access_token":"oauth-access-9999","account_id":"acct-42"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"

Passively the route is visible and unchecked, fingerprinted by the stable
account id rather than rotating token material.

  $ spice auth status openai --json | grep -o '"route":"openai/oauth".*"fingerprint":"acct-42".*"phase":"unchecked"' | grep -c .
  spice: warning: $TESTCASE_ROOT/xdg-config/spice/auth.json permissions are 0644, expected 0600
  1

A refresh validates against the route's model-list endpoint, sending the
account-scoping header.

  $ cat > script-models.jsonl <<'JSONL'
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":200,"json":{"data":[{"id":"gpt-5.5"}]}}}
  > JSONL
  $ start_fake_server script-models.jsonl capture-models port-models
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-models)/v1"
  $ spice auth status openai --refresh --json | grep -o '"phase":"ready"'
  spice: warning: $TESTCASE_ROOT/xdg-config/spice/auth.json permissions are 0644, expected 0600
  "phase":"ready"
  $ wait_fake_server
  $ grep -c "chatgpt-account-id: acct-42" capture-models/request-1.headers
  1

Execution uses the same route: bearer access token plus the account header,
standard Responses API body.

  $ cat > script-exec.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":["\"model\":\"gpt-5.5\"","oauth prompt"]},"response":{"id":"resp-oauth","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"oauth final answer"}]}]}}
  > JSONL
  $ start_fake_server script-exec.jsonl capture-exec port-exec
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-exec)/v1"
  $ spice run --cwd "$PWD" --id oauth-run "oauth prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  oauth final answer
  spice: session saved; resume with: spice resume 'oauth-run'
  $ wait_fake_server
  $ grep -c "chatgpt-account-id: acct-42" capture-exec/request-1.headers
  1

Token material never appears in status output.

  $ spice auth status openai --json | grep -c "oauth-access-9999"
  spice: warning: $TESTCASE_ROOT/xdg-config/spice/auth.json permissions are 0644, expected 0600
  0
  [1]
