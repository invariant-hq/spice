Stored OAuth credentials refresh before expiry under their credential-slot
lock: snapshot briefly under the store lock, refresh once without holding it,
then commit only if the secret is unchanged. Rotated refresh tokens are never
spent twice, and permanent rejections block later runs until the user logs in
again.

  $ export SPICE_MODEL=openai/gpt-5.5
  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ expired_credential () {
  >   printf '{"version":1,"credentials":{"openai":{"default":{"kind":"oauth","access_token":"oauth-access-old","refresh_token":"refresh-r1","expires_at":1,"account_id":"acct-42"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  > }
  $ sse_item () {
  >   printf '{"expect":{"request_line":"POST /v1/responses HTTP/1.1"},"response":{"id":"resp-%s","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"refreshed answer"}]}]}}\n' "$1"
  > }

A run against an expired credential refreshes once; a second run reloads the
fresh credential and skips the token endpoint entirely.

  $ expired_credential
  $ cat > script-seq.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1","body_contains":["\"grant_type\":\"refresh_token\""]},"http":{"status":200,"json":{"access_token":"oauth-access-new","refresh_token":"refresh-r2","expires_in":3600}}}
  > JSONL
  $ sse_item seq-1 >> script-seq.jsonl
  $ sse_item seq-2 >> script-seq.jsonl
  $ start_fake_server script-seq.jsonl capture-seq port-seq
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-seq)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-seq)"
  $ spice run --cwd "$PWD" --id refresh-run-1 "first prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  refreshed answer
  spice: session saved; resume with: spice resume 'refresh-run-1'
  $ spice run --cwd "$PWD" --id refresh-run-2 "second prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  refreshed answer
  spice: session saved; resume with: spice resume 'refresh-run-2'
  $ wait_fake_server
  $ grep -l "grant_type" capture-seq/request-*.json | wc -l | tr -d ' '
  1
  $ grep -c "authorization: Bearer oauth-access-new" capture-seq/request-2.headers
  1

The rotated secret is persisted and the stable account-id fingerprint keeps
the credential's identity across rotation.

  $ grep -c "refresh-r2" "$XDG_CONFIG_HOME/spice/auth.json"
  1
  $ spice auth status openai --json | grep -o '"fingerprint":"acct-42"'
  "fingerprint":"acct-42"

Two concurrent runs against an expired credential spend exactly one refresh:
the credential-slot lock serializes them and the loser reloads the winner's
fresh credential instead of re-sending the rotated token.

  $ expired_credential
  $ cat > script-par.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1"},"delay_ms":500,"http":{"status":200,"json":{"access_token":"oauth-access-par","refresh_token":"refresh-r3","expires_in":3600}}}
  > JSONL
  $ sse_item par-1 >> script-par.jsonl
  $ sse_item par-2 >> script-par.jsonl
  $ start_fake_server script-par.jsonl capture-par port-par
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-par)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-par)"
  $ spice run --cwd "$PWD" --id par-run-1 "race prompt" > par-1.out & first=$!
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session saved; resume with: spice resume 'par-run-1'
  $ spice run --cwd "$PWD" --id par-run-2 "race prompt" > par-2.out & second=$!
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session saved; resume with: spice resume 'par-run-2'
  $ wait "$first" && wait "$second"
  $ cat par-1.out par-2.out
  refreshed answer
  refreshed answer
  $ wait_fake_server
  $ grep -l "grant_type" capture-par/request-*.json | wc -l | tr -d ' '
  1
  $ grep -h "authorization: Bearer oauth-access-par" capture-par/request-*.headers | wc -l | tr -d ' '
  2

A slow refresh owns only its credential slot. Unrelated store writes commit
while the token endpoint is still pending, and the later refresh commit
preserves them.

  $ expired_credential
  $ cat > script-unrelated.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1"},"delay_ms":2000,"http":{"status":200,"json":{"access_token":"oauth-access-unrelated","refresh_token":"refresh-r4","expires_in":3600}}}
  > JSONL
  $ sse_item unrelated >> script-unrelated.jsonl
  $ start_fake_server script-unrelated.jsonl capture-unrelated port-unrelated
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-unrelated)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-unrelated)"
  $ spice run --cwd "$PWD" --id unrelated-run "slow refresh" > unrelated.out 2> unrelated.err & refresher=$!
  $ wait_for_file capture-unrelated/request-1.json
  $ printf other-provider-key | spice auth save anthropic --api-key-stdin > unrelated-save.out & saver=$!
  $ wait_for_output "Saved anthropic credential default" unrelated-save.out 20
  $ kill -0 "$refresher" && echo refresh-still-pending
  refresh-still-pending
  $ wait "$saver" && wait "$refresher"
  $ cat unrelated.out
  refreshed answer
  $ wait_fake_server
  $ spice auth status anthropic --json | grep -o '"fingerprint":"-key"'
  "fingerprint":"-key"

A replacement written into the refreshing slot wins. The stale token response
is neither persisted nor used for the model request.

  $ expired_credential
  $ cat > script-replaced.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1"},"delay_ms":2000,"http":{"status":200,"json":{"access_token":"oauth-access-stale","refresh_token":"refresh-stale","expires_in":3600}}}
  > JSONL
  $ sse_item replaced >> script-replaced.jsonl
  $ start_fake_server script-replaced.jsonl capture-replaced port-replaced
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-replaced)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-replaced)"
  $ spice run --cwd "$PWD" --id replaced-run "replace during refresh" > replaced.out 2> replaced.err & refresher=$!
  $ wait_for_file capture-replaced/request-1.json
  $ printf replacement-api-key | spice auth save openai --api-key-stdin
  Saved openai credential default
  $ kill -0 "$refresher" && echo refresh-still-pending
  refresh-still-pending
  $ wait "$refresher"
  $ cat replaced.out
  refreshed answer
  $ wait_fake_server
  $ grep -c "authorization: Bearer replacement-api-key" capture-replaced/request-2.headers
  1
  $ grep -c "replacement-api-key" "$XDG_CONFIG_HOME/spice/auth.json"
  1
  $ grep -Ec "oauth-access-stale|refresh-stale" "$XDG_CONFIG_HOME/spice/auth.json"
  0
  [1]

A provider 401 during a run forces one refresh and one retry, even when the
local expiry looked fine — the provider is the authority on token validity.

  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"oauth","access_token":"oauth-access-revoked","refresh_token":"refresh-r10","expires_at":9999999999,"account_id":"acct-42"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ cat > script-retry.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/responses HTTP/1.1"},"http":{"status":401,"json":{"error":{"message":"token expired"}}}}
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1","body_contains":["\"grant_type\":\"refresh_token\""]},"http":{"status":200,"json":{"access_token":"oauth-access-retried","refresh_token":"refresh-r11","expires_in":3600}}}
  > JSONL
  $ sse_item retry-1 >> script-retry.jsonl
  $ start_fake_server script-retry.jsonl capture-retry port-retry
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-retry)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-retry)"
  $ spice run --cwd "$PWD" --id retry-run "retry prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  refreshed answer
  spice: session saved; resume with: spice resume 'retry-run'
  $ wait_fake_server
  $ grep -c "authorization: Bearer oauth-access-retried" capture-retry/request-3.headers
  1

A provider rejection followed by a permanent forced-refresh failure reports
the newer blocked-credential diagnosis, rather than hiding it behind the 401
that initiated recovery.

  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"oauth","access_token":"oauth-access-revoked","refresh_token":"refresh-dead","expires_at":9999999999,"account_id":"acct-42"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ cat > script-retry-fail.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/responses HTTP/1.1"},"http":{"status":401,"json":{"error":{"message":"token expired"}}}}
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1"},"http":{"status":400,"json":{"error":"invalid_grant"}}}
  > JSONL
  $ start_fake_server script-retry-fail.jsonl capture-retry-fail port-retry-fail
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-retry-fail)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-retry-fail)"
  $ spice run --cwd "$PWD" --id retry-fail-run "retry doomed prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: blocked credential for provider openai: refresh_failed
  Hint: run `spice auth status openai` and the repair command it names
  Hint: check the provider login or credential
  [1]
  $ wait_fake_server

A permanent refresh rejection fails the run that discovered it, immediately
and with repair guidance — live knowledge, nothing cached. The session
document is not created, and a later run learns the same truth the same way.

  $ expired_credential
  $ cat > script-fail.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1"},"http":{"status":400,"json":{"error":"invalid_grant"}}}
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1"},"http":{"status":400,"json":{"error":"invalid_grant"}}}
  > JSONL
  $ start_fake_server script-fail.jsonl capture-fail port-fail
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-fail)/v1"
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-fail)"
  $ spice run --cwd "$PWD" --id fail-run-1 "doomed prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: blocked credential for provider openai: refresh_failed
  Hint: run `spice auth status openai` and the repair command it names
  [1]
  $ test -e $SPICE_TEST_DATA_HOME/sessions/fail-run-1/session.log || echo not-created
  not-created
  $ spice run --cwd "$PWD" --id fail-run-2 "doomed prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: blocked credential for provider openai: refresh_failed
  Hint: run `spice auth status openai` and the repair command it names
  [1]
  $ wait_fake_server
  $ spice auth status openai --json | grep -o '"phase":"[a-z]*"'
  "phase":"unchecked"
