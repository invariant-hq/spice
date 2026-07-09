The local auth store persists API-key credentials without printing secret
material.

  $ git init -q

API-key login is the primary lifecycle path. It reads secret material from
stdin, stores it under the default name, validates it against the provider,
and never prints it. The provider endpoint here points at a closed port, so
validation degrades with a transient network problem without leaving the
machine — the credential is saved either way.

  $ export SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1
  $ printf login-key | spice auth login openai --method api-key --api-key-stdin | sed -E 's#\(file store [^)]+\)#(file store $AUTH)#'
  Logged in to openai with api-key.
  Saved:   default (file store $AUTH)
  Checked: degraded (network)
  Next:    spice auth status openai --refresh
  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"store","source_name":"default","fingerprint":"-key","env":["OPENAI_API_KEY"],"store_names":["default"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  $ spice auth status openai --json | grep login-key || echo redacted
  redacted

Logout removes the default credential.

  $ spice auth logout openai
  Removed openai credential default
  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  [1]

The save/remove aliases preserve the API-key lifecycle for script-friendly
callers.

  $ printf alias-key | spice auth save anthropic --api-key-stdin
  Saved anthropic credential default
  $ spice auth status anthropic
  auth_store_path: $TESTCASE_ROOT/xdg-config/spice/auth.json
  storage_backend: file
  PROVIDER   ROUTE    SOURCE         KEY    PHASE      CHECKED  ENV                STORE_NAMES
  anthropic  api-key  store:default  …-key  unchecked  -        ANTHROPIC_API_KEY  default
  Hint: run `spice auth status anthropic --refresh`
  $ spice auth remove anthropic
  Removed anthropic credential default

Named credentials are explicit. A named credential appears in status
[store_names], does not satisfy the default lookup, and does satisfy a lookup
with the same name.

  $ printf work-key | spice auth save openai --name work --api-key-stdin
  Saved openai credential work
  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":["work"],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  [1]
  $ spice auth status openai --name work --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"store","source_name":"work","fingerprint":"-key","env":["OPENAI_API_KEY"],"store_names":["work"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  $ spice auth status openai --name work --json | grep work-key || echo redacted
  redacted
  $ spice auth remove openai --name work
  Removed openai credential work
