Browser OAuth login runs end to end against a local fake issuer: the CLI
prints the authorization URL, listens on the loopback callback, exchanges the
authorization code, and settles through the persist-then-check policy. The
auth base-URL override reroots the authorization and token endpoints onto the
fake issuer, the provider base-URL override routes the post-save check there
too, and the fake server binary's one-shot --get client plays the browser.

  $ cat > script-browser.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/token HTTP/1.1","body_contains":["grant_type=authorization_code","code=browser-code-1"]},"http":{"status":200,"json":{"id_token":"e30.e30.e30","access_token":"oauth-access-browser","refresh_token":"refresh-browser-1","expires_in":3600,"token_type":"Bearer"}}}
  > {"expect":{"request_line":"GET /v1/models HTTP/1.1"},"http":{"status":200,"json":{"data":[{"id":"gpt-5.5"}]}}}
  > JSONL
  $ start_fake_server script-browser.jsonl capture-browser port-browser
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-browser)"
  $ export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat port-browser)/v1"

The login blocks on the browser callback, so it runs in the background while
this test plays the browser.

  $ spice auth login openai --method browser > login.log 2>&1 &
  $ SPICE_LOGIN_PID=$!
  $ wait_for_output "Waiting for authorization" login.log

A stray request to the callback port — here a forged state — is answered with
an error page and does not consume the attempt: the listener keeps waiting
for the redirect that belongs to this authorization.

  $ fake_browser_get "http://localhost:1455/auth/callback?code=evil&state=forged"
  400

The real redirect carries the state minted for this attempt. The code is
exchanged at the fake issuer and the saved credential checked against the
fake model-list endpoint.

  $ state=$(grep -o 'state=[A-Za-z0-9_-]*' login.log | head -n 1 | sed 's/state=//')
  $ fake_browser_get "http://localhost:1455/auth/callback?code=browser-code-1&state=$state"
  200
  $ wait "$SPICE_LOGIN_PID"
  $ sed -E -e 's#http://127.0.0.1:[0-9]+#http://FAKE#g' -e 's#\?[^ ]*#?...#' -e 's/validated [0-9TZ:.-]+/validated TS/' login.log
  Go to: http://FAKE/oauth/authorize?...
  Listening for the browser callback on http://localhost:1455/auth/callback
  Waiting for authorization (300s timeout)...
  Logged in to openai with browser.
  Saved:   default (file store $TESTCASE_ROOT/xdg-config/spice/auth.json)
  Checked: ready (validated TS)
  Next:    spice run --model openai/gpt-5.5 "..."
  $ wait_fake_server

The saved credential is the OAuth route; token material never appears in
status output.

  $ spice auth status openai --json | grep -o '"route":"openai/oauth"'
  "route":"openai/oauth"
  $ spice auth status openai --json | grep -Ec "oauth-access-browser|refresh-browser-1"
  0
  [1]
  $ spice auth logout openai
  Removed openai credential default
