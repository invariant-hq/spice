Auth status is passive, local, and credential-free.

With no credentials, one provider has an exact missing status shape.

  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  [1]

The provider option is equivalent to the positional provider argument.

  $ spice auth status --provider openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  [1]

The all-provider view lists registered providers, without duplicating the full
provider catalog in this test.

  $ spice auth status --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login openai","selected_model":{"selector":"openai/gpt-5.5","available":null}},{"provider":"anthropic","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["ANTHROPIC_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login anthropic"},{"provider":"google","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["GOOGLE_API_KEY","GOOGLE_GENERATIVE_AI_API_KEY","GEMINI_API_KEY"],"store_names":[],"phase":"missing","checked_at":null,"problems":[],"transient":false,"repair":"spice auth login google"},{"provider":"deepseek","route":null,"source":null,"source_name":null,"fingerprint":null,"env":[],"store_names":[],"phase":"ready","checked_at":null,"problems":[],"transient":false,"repair":null},{"provider":"local","route":null,"source":null,"source_name":null,"fingerprint":null,"env":[],"store_names":[],"phase":"ready","checked_at":null,"problems":[],"transient":false,"repair":null},{"provider":"ollama","route":null,"source":null,"source_name":null,"fingerprint":null,"env":["OLLAMA_API_KEY"],"store_names":[],"phase":"ready","checked_at":null,"problems":[],"transient":false,"repair":null}],"summary":{"selected_route":{"provider":"openai","model":"openai/gpt-5.5","phase":"missing"}}}

Credentialless providers are auth-ready and never suggest a login repair.

  $ spice auth status deepseek --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"deepseek","route":null,"source":null,"source_name":null,"fingerprint":null,"env":[],"store_names":[],"phase":"ready","checked_at":null,"problems":[],"transient":false,"repair":null}]}

An optional-auth provider (Ollama) with a stored credential keeps its real
phase — the credential is reported, not masked to the no-login-needed ready.
Only the missing phase reads as ready where auth is optional.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"version":1,"credentials":{"ollama":{"default":{"kind":"api_key","api_key":"lab-key-1234"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ chmod 600 "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice auth status ollama --json | grep -o '"route":"ollama/api-key"'
  "route":"ollama/api-key"
  $ spice auth status ollama --json | grep -o '"phase":"unchecked"'
  "phase":"unchecked"
  $ rm "$XDG_CONFIG_HOME/spice/auth.json"
  $ spice auth status ollama --json | grep -o '"phase":"ready"'
  "phase":"ready"

Text output is a compact table for humans.

  $ spice auth status openai
  auth_store_path: $TESTCASE_ROOT/xdg-config/spice/auth.json
  storage_backend: file
  PROVIDER  ROUTE  SOURCE  KEY  PHASE    CHECKED  ENV             STORE_NAMES
  openai    -      -       -    missing  -        OPENAI_API_KEY  -
  Hint: run `spice auth login openai`
  [1]

Environment credentials are detected through provider declarations and are not
printed.

  $ OPENAI_API_KEY=dummy spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"env","source_name":"OPENAI_API_KEY","fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":[],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}

  $ OPENAI_API_KEY=dummy spice auth status openai --json | grep dummy || echo redacted
  redacted

Non-OpenAI API-key providers use the same passive status shape.

  $ GOOGLE_GENERATIVE_AI_API_KEY=google-secret spice auth status google --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"google","route":"google/api-key","source":"env","source_name":"GOOGLE_GENERATIVE_AI_API_KEY","fingerprint":"cret","env":["GOOGLE_API_KEY","GOOGLE_GENERATIVE_AI_API_KEY","GEMINI_API_KEY"],"store_names":[],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status google --refresh","selected_model":{"selector":"google/gemini-3.5-flash","available":null}}]}

Removed auth subcommands report the supported command set.

  $ spice auth where openai | sed -E 's#auth_store_path: .*/xdg-config/#auth_store_path: $XDG_CONFIG_HOME/#'
  Usage: spice auth [--help] COMMAND …
  spice: unknown command 'where'. Must be one of 'login', 'logout', 'remove',
         'save' or 'status'
  [124]

The JSON spelling is rejected by the same command parser.

  $ spice auth where openai --json | sed -E 's#"auth_store_path":"[^"]+"#"auth_store_path":"$AUTH"#'
  Usage: spice auth [--help] COMMAND …
  spice: unknown command 'where'. Must be one of 'login', 'logout', 'remove',
         'save' or 'status'
  [124]
