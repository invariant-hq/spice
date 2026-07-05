Logout with --revoke attempts provider revocation for stored OAuth
credentials before removing them locally. Revocation failure never strands
the user: the local credential is removed anyway, with a warning saying so.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ oauth_credential () {
  >   printf '{"version":1,"credentials":{"openai":{"default":{"kind":"oauth","access_token":"oauth-access-9999","refresh_token":"refresh-r1","account_id":"acct-42"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  > }

Successful revocation prefers the refresh token and removes locally.

  $ oauth_credential
  $ cat > script-revoke.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /oauth/revoke HTTP/1.1","body_contains":["\"token_type_hint\":\"refresh_token\""]},"http":{"status":200,"json":{}}}
  > JSONL
  $ start_fake_server script-revoke.jsonl capture-revoke port-revoke
  $ export SPICE_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat port-revoke)"
  $ spice auth logout openai --revoke
  Revoked openai credential
  Removed openai credential default
  $ wait_fake_server
  $ spice auth names openai --json
  Usage: spice auth [--help] COMMAND …
  spice: unknown command names. Must be one of login, logout, remove, save or
         status
  [124]

Transient revocation failure still removes the local credential and says so.
The endpoint here is a closed port.

  $ oauth_credential
  $ export SPICE_OPENAI_AUTH_BASE_URL=http://127.0.0.1:9
  $ spice auth logout openai --revoke 2>revoke-warning.txt
  Removed openai credential default
  $ grep -c "revocation failed" revoke-warning.txt
  1
  $ grep -c "removing the local credential anyway" revoke-warning.txt
  1
  $ spice auth names openai --json
  Usage: spice auth [--help] COMMAND …
  spice: unknown command names. Must be one of login, logout, remove, save or
         status
  [124]

API-key credentials do not support provider revocation; --revoke says so and
removes locally without any provider request.

  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"api_key","api_key":"sk-test-abcd1234"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice auth logout openai --revoke
  The stored credential does not support provider revocation.
  Removed openai credential default

Logging out a stored credential while an environment credential is active
says the environment credential survives.

  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"api_key","api_key":"sk-test-abcd1234"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ OPENAI_API_KEY=sk-env-key-zzz9 spice auth logout openai
  Removed openai credential default
  Environment credential OPENAI_API_KEY is still active and cannot be removed by Spice.
