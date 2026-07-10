OAuth login flows are TTY-sensitive and testable against a local fake auth
issuer through the auth base-URL override.

Without a terminal, plain `spice auth login openai` refuses to pick a method
silently: the default is the browser flow, which needs a TTY.

  $ spice auth login openai
  spice: auth login openai needs an explicit method without a terminal; use `--method device-code` or `--method api-key --api-key-stdin`
  [2]

The OpenAI device-code flow prints the verification challenge with a phishing
warning, polls until authorized, exchanges the code, and saves the OAuth
credential. The fake issuer scripts the user-code, device-token, and token
endpoints; the device-token response carries a real PKCE pair.

  $ cat > script-device.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /api/accounts/deviceauth/usercode HTTP/1.1"},"http":{"status":200,"json":{"device_auth_id":"dev-1","user_code":"CODE-1234","expires_in":300,"interval":0}}}
  > {"expect":{"request_line":"POST /api/accounts/deviceauth/token HTTP/1.1"},"http":{"status":200,"json":{"authorization_code":"auth-code-1","code_challenge":"7HWTEa2cNqSU6dY1pSKj_i_9al1m6oEXjMUJBGJybWE","code_verifier":"test-verifier-test-verifier-test-verifier-1"}}}
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1","body_contains":["grant_type=authorization_code","code=auth-code-1"]},"http":{"status":200,"json":{"id_token":"e30.e30.e30","access_token":"oauth-access-device","refresh_token":"refresh-device-1","expires_in":3600}}}
  > JSONL
  $ start_fake_server script-device.jsonl capture-device port-device
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-device)"
  $ spice auth login openai --method device-code | sed -E 's#http://127.0.0.1:[0-9]+#http://FAKE#'
  Go to: http://FAKE/codex/device
  Enter code: CODE-1234
  Device codes are a common phishing target. Never share this code.
  Waiting for authorization...
  Logged in to openai with device-code.
  Saved:   default (file store $TESTCASE_ROOT/xdg-config/spice/auth.json)
  Checked: blocked (invalid_credential)
  Next:    spice auth status openai
  [1]
  $ wait_fake_server

The saved credential is the OAuth route, fingerprinted and redacted.

  $ spice auth status openai --json | grep -o '"route":"openai/oauth"'
  "route":"openai/oauth"
  $ spice auth status openai --json | grep -c "oauth-access-device"
  0
  [1]
  $ spice auth logout openai
  Removed openai credential default

A device poll that is still pending (the device-token endpoint answers 403)
loops silently on the schedule and only saves once the code is authorized. The
zero interval keeps the retry immediate; the extra 403 exercises the unified
machine's pending branch before the authorized exchange.

  $ cat > script-pending.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /api/accounts/deviceauth/usercode HTTP/1.1"},"http":{"status":200,"json":{"device_auth_id":"dev-3","user_code":"CODE-PEND","expires_in":300,"interval":0}}}
  > {"expect":{"request_line":"POST /api/accounts/deviceauth/token HTTP/1.1"},"http":{"status":403,"json":{}}}
  > {"expect":{"request_line":"POST /api/accounts/deviceauth/token HTTP/1.1"},"http":{"status":200,"json":{"authorization_code":"auth-code-3","code_challenge":"7HWTEa2cNqSU6dY1pSKj_i_9al1m6oEXjMUJBGJybWE","code_verifier":"test-verifier-test-verifier-test-verifier-1"}}}
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1","body_contains":["grant_type=authorization_code","code=auth-code-3"]},"http":{"status":200,"json":{"id_token":"e30.e30.e30","access_token":"oauth-access-pending","refresh_token":"refresh-pending-1","expires_in":3600}}}
  > JSONL
  $ start_fake_server script-pending.jsonl capture-pending port-pending
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-pending)"
  $ spice auth login openai --method device-code | sed -E 's#http://127.0.0.1:[0-9]+#http://FAKE#'
  Go to: http://FAKE/codex/device
  Enter code: CODE-PEND
  Device codes are a common phishing target. Never share this code.
  Waiting for authorization...
  Logged in to openai with device-code.
  Saved:   default (file store $TESTCASE_ROOT/xdg-config/spice/auth.json)
  Checked: blocked (invalid_credential)
  Next:    spice auth status openai
  [1]
  $ wait_fake_server

Neither the access token nor the refresh token appears in status output.

  $ spice auth status openai --json | grep -Ec "oauth-access-pending|refresh-pending-1"
  0
  [1]
  $ spice auth logout openai
  Removed openai credential default

A device authorization that expires reports the expiry, and saves nothing.

  $ cat > script-expired.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /api/accounts/deviceauth/usercode HTTP/1.1"},"http":{"status":200,"json":{"device_auth_id":"dev-2","user_code":"CODE-9999","expires_in":0,"interval":0}}}
  > JSONL
  $ start_fake_server script-expired.jsonl capture-expired port-expired
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-expired)"
  $ spice auth login openai --method device-code 2>&1 | sed -E 's#http://127.0.0.1:[0-9]+#http://FAKE#'
  Go to: http://FAKE/codex/device
  Enter code: CODE-9999
  Device codes are a common phishing target. Never share this code.
  Waiting for authorization...
  spice: device code expired — run the login again
  [1]
  $ wait_fake_server
  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  [1]
