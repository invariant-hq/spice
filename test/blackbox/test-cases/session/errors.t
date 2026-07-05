Session commands report invalid inputs and runtime failures without creating or
mutating unrelated documents.

Duplicate ids are rejected.

  $ spice session create --id demo --title Demo
  demo
  $ spice session create --id demo
  spice: session already exists: demo
  [1]
  $ cat .spice/sessions/demo/session.json | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"demo","metadata":{"title":"Demo","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Empty titles are usage errors and do not create documents.

  $ spice session create --id empty --title ''
  spice: session title must not be empty
  [2]
  $ test -e .spice/sessions/empty/session.json || echo not-created
  not-created
  $ spice session fork demo --id empty-child --title ''
  spice: session title must not be empty
  [2]
  $ test -e .spice/sessions/empty-child/session.json || echo not-created
  not-created
  $ spice session rename demo ''
  spice: session title must not be empty
  [2]

Missing sessions fail consistently across read and lifecycle commands.

  $ spice session show missing
  spice: session not found: missing
  [1]
  $ spice session export missing
  spice: session not found: missing
  [1]
  $ spice session archive missing
  spice: session not found: missing
  [1]
  $ spice session restore missing
  spice: session not found: missing
  [1]
  $ spice session rename missing New
  spice: session not found: missing
  [1]
  $ spice session delete --yes missing
  spice: session not found: missing
  [1]
  $ spice session fork missing --id child
  spice: session not found: missing
  [1]
  $ SPICE_MODEL=openai/gpt-5.5 spice session compact missing
  spice: session not found: missing
  [1]
  $ SPICE_MODEL=openai/gpt-5.5 spice session compact missing
  spice: session not found: missing
  [1]

Manual compaction assembles the runtime before mutating the saved session.

  $ SPICE_MODEL=openai/gpt-5.5 spice session compact demo
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ cat .spice/sessions/demo/session.json | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"demo","metadata":{"title":"Demo","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

List/search limits must be positive.

  $ spice session list --limit 0
  ID    PHASE  AGE       TITLE
  demo  idle   just now  Demo
  $ spice session list --limit=-1
  spice: session list limit must be positive: -1
  [2]
  $ spice session search --limit 0 Demo
  ID    PHASE  AGE       TITLE
  demo  idle   just now  Demo

Delete requires an explicit confirmation before loading or mutating a session.

  $ spice session delete demo
  spice: session delete requires --yes
  [2]
  $ cat .spice/sessions/demo/session.json | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"demo","metadata":{"title":"Demo","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Unknown export formats are rejected by command-line parsing.

  $ spice session export --format xml demo 2>&1 | sed -n "s/.*format.*/invalid-format/p" | head -1
  invalid-format
  [124]

Empty session ids are rejected by command-line parsing.

  $ spice session create --id '' >err 2>&1; echo "status:$?"; sed -n '1p; s/.*invalid session id "": id must not be empty.*/invalid-id/p' err
  status:124
  Usage: spice session create [--help] [--id=ID] [--json] [--title=TITLE]
  invalid-id
  $ spice session show ''
  Usage: spice session show [--help] [--json] [--last] [OPTION]… [SESSION]
  spice: SESSION argument: invalid session id "": id must not be empty
  [124]

User-facing errors do not leak stale internal names from previous designs.

  $ spice session show missing 2>&1 | grep -E 'Load''ed|Spice_host[.]Session|test_host_''session' || echo no-stale-names
  no-stale-names
