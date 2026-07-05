Session management commands persist full Spice session documents under the host
store root.

Creating a session writes a canonical document and makes it visible in ordinary
lists.

  $ spice session create --id demo --title Demo
  demo
  $ test -f .spice/sessions/demo/session.json && echo saved
  saved
  $ cat .spice/sessions/demo/session.json | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"demo","metadata":{"title":"Demo","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Text output is compact and stable for the common inspection path.

  $ spice session list
  ID    PHASE  AGE       TITLE
  demo  idle   just now  Demo
  $ spice session show demo | sed -E 's/revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/; s/(created|updated)_at: [0-9]+/\1_at: $TIME/'
  id: demo
  title: Demo
  preview: -
  lifecycle: active
  phase: idle
  events: 0
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH

The old info alias is gone; show is the single inspection command.

  $ spice session info demo 2>&1 | head -1
  Usage: spice session [--help] COMMAND …
  [124]

Renaming is a metadata update over the saved document.

  $ spice session rename demo Renamed
  demo
  $ spice session show demo | grep '^title'
  title: Renamed
  $ spice session rename demo Demo
  demo

Untitled sessions display [-] in text output and omit title from the canonical
document metadata.

  $ spice session create --id untitled
  untitled
  $ spice session show untitled | sed -E 's/revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/; s/(created|updated)_at: [0-9]+/\1_at: $TIME/'
  id: untitled
  title: -
  preview: -
  lifecycle: active
  phase: idle
  events: 0
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  $ spice session export untitled | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"untitled","metadata":{"status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Session ids are not filesystem path components. The host encodes the storage
directory and preserves the exact id inside the saved document.

  $ spice session create --id 'unsafe/id with space' --title Unsafe
  unsafe/id with space
  $ test -f '.spice/sessions/unsafe%2Fid%20with%20space/session.json' && echo escaped
  escaped
  $ spice session export 'unsafe/id with space' | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"unsafe/id with space","metadata":{"title":"Unsafe","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Export prints the canonical Spice session document JSON, not the CLI summary
envelope.

  $ spice session export demo | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"demo","metadata":{"title":"Demo","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}
  $ spice session export --format json demo | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"demo","metadata":{"title":"Demo","status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}

Text and markdown exports provide simple human-readable projections.

  $ spice session export --format text demo
  id: demo
  title: Demo
  status: active
  events: 0
  $ spice session export --format markdown demo
  # Session demo
  - Title: Demo
  - Status: active
  - Events: 0
