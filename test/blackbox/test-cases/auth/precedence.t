Credential resolution is deterministic.

  $ git init -q

Stored credentials are used when no process or environment credential is
available.

  $ printf stored-key | spice auth save openai --api-key-stdin
  Saved openai credential default
  $ spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"store","source_name":"default","fingerprint":"-key","env":["OPENAI_API_KEY"],"store_names":["default"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}

Environment credentials take precedence over stored credentials.

  $ OPENAI_API_KEY=env-key spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"env","source_name":"OPENAI_API_KEY","fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":["default"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}

Empty environment variables are ignored and fall back to the store.

  $ OPENAI_API_KEY= spice auth status openai --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"store","source_name":"default","fingerprint":"-key","env":["OPENAI_API_KEY"],"store_names":["default"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}

Named credentials select only the stored fallback. Environment credentials still
win for the resolved credential.

  $ printf work-key | spice auth save openai --name work --api-key-stdin
  Saved openai credential work
  $ spice auth status openai --name work --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"store","source_name":"work","fingerprint":"-key","env":["OPENAI_API_KEY"],"store_names":["default","work"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}
  $ OPENAI_API_KEY=env-key spice auth status openai --name work --json
  {"schema_version":3,"type":"auth_status","storage_backend":"file","auth_store_path":"$TESTCASE_ROOT/xdg-config/spice/auth.json","providers":[{"provider":"openai","route":"openai/api-key","source":"env","source_name":"OPENAI_API_KEY","fingerprint":null,"env":["OPENAI_API_KEY"],"store_names":["default","work"],"phase":"unchecked","checked_at":null,"problems":[],"transient":false,"repair":"spice auth status openai --refresh","selected_model":{"selector":"openai/gpt-5.5","available":null}}]}

Secret values are never printed in status output.

  $ spice auth status openai --name work --json | grep -E 'stored-key|work-key' || echo redacted
  redacted
