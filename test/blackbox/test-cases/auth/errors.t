Auth commands fail before mutating state when the provider, method, name, store,
or credential material is invalid.

  $ git init -q

Unknown providers are usage errors for reads and writes.

  $ spice auth status nope
  spice: unknown provider: nope
  [2]

  $ printf key | spice auth login nope --method api-key --api-key-stdin
  spice: unknown provider: nope
  [2]

Invalid provider ids are reported as user-facing input errors.

  $ spice auth status OpenAI
  Usage: spice auth status [--help] [OPTION]… [PROVIDER]
  spice: PROVIDER argument: invalid provider id "OpenAI": id must start with a
         lowercase ASCII letter
  [124]

The positional provider and --provider alias must agree when both are present.

  $ spice auth status openai --provider anthropic
  spice: provider specified twice with different values: openai and anthropic
  [2]

API-key login requires stdin so secrets are never accepted as command-line
arguments.

  $ spice auth login openai --method api-key
  spice: auth login --method api-key requires --api-key-stdin
  [2]

  $ spice auth save openai
  spice: auth save requires --api-key-stdin
  [2]

Anthropic has no interactive method today, so bare login falls back to API-key
login and also requires stdin.

  $ spice auth login anthropic
  spice: auth login --method api-key requires --api-key-stdin
  [2]

Empty API-key input is rejected before a credential is saved.

  $ printf '' | spice auth login openai --method api-key --api-key-stdin
  spice: API key must not be empty
  [2]

Invalid credential names are rejected before mutation.

  $ printf key | spice auth login openai --name bad/name --method api-key --api-key-stdin >err 2>&1; echo "status:$?"; sed -n '1p; s/.*invalid credential name "bad\/name".*/invalid-name/p' err
  status:124
  Usage: spice auth login [--help] [--api-key-stdin] [--method=METHOD]
  invalid-name

Unsupported methods are reported from each provider's auth declaration.

  $ spice auth login anthropic --method browser
  spice: unknown auth method "browser" for provider anthropic
  [2]

  $ spice auth login google --method device-code
  spice: unknown auth method "device-code" for provider google
  [2]

The API-key stdin flag is rejected for declared interactive login methods before
any browser, callback server, or network work starts. Undeclared methods fail at
selection.

  $ spice auth login openai --method browser --api-key-stdin
  spice: --api-key-stdin cannot be used with browser login
  [2]

  $ spice auth login openai --method device-code --api-key-stdin
  spice: --api-key-stdin cannot be used with device-code login
  [2]

A stored credential kind the provider cannot serve is rejected when the client
is built, never sent as a stale substitute: Anthropic has no OAuth flow, so an
OAuth secret must not ride as a bearer token that nothing refreshes.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"version":1,"credentials":{"anthropic":{"default":{"kind":"oauth","access_token":"oauth-anthropic-1"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice run --cwd "$PWD" --model anthropic/claude-sonnet-5 "hi"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: unsupported credential kind oauth for provider anthropic
  [1]
  $ rm "$XDG_CONFIG_HOME/spice/auth.json"

A malformed auth store fails loudly, naming the file, rather than reading as
empty and quietly losing every stored credential.

  $ printf '{"version":' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice auth status openai --json
  spice: $TESTCASE_ROOT/xdg-config/spice/auth.json: Expected JSON value but found end of text
  File "-", line 1, characters 11-12:
  File "-": in member version of
  File "-", line 1, characters 0-12: object
  [1]

Unsupported auth store versions fail loudly.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"version":2,"credentials":[]}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice auth status openai --json
  spice: $TESTCASE_ROOT/xdg-config/spice/auth.json: unsupported account store version: 2
  [1]

Non-file auth store paths fail loudly.

  $ rm "$XDG_CONFIG_HOME/spice/auth.json"
  $ mkdir "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice auth status openai --json
  spice: $TESTCASE_ROOT/xdg-config/spice/auth.json: is a directory
  [1]
  $ rmdir "$XDG_CONFIG_HOME/spice/auth.json"

No failing command created stored credentials.

  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  [1]
