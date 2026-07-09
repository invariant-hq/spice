Host session persistence loads canonical documents from disk and reports invalid
stored state as recoverable CLI errors.

Listing is rebuildable from session documents and ignores directories that do
not contain a session document.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/empty-dir
  $ spice session list
  ID  PHASE  AGE  TITLE

Manually seeded canonical documents are listed and can be shown/exported.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/manual
  $ printf '%s\n' "{\"version\":1,\"id\":\"manual\",\"metadata\":{\"title\":\"Manual\",\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":1},\"events\":[]}" > $SPICE_TEST_DATA_HOME/sessions/manual/session.json

The AGE column renders against the injected SPICE_NOW clock, so crafted
timestamps stay deterministic.

  $ SPICE_NOW=90000001 spice session list
  ID      PHASE  AGE     TITLE
  manual  idle   1d ago  Manual
  $ spice session export manual
  {"version":1,"id":"manual","metadata":{"title":"Manual","status":"active","cwd":"$TESTCASE_ROOT","created_at":1,"updated_at":1},"events":[]}

The requested id must match the id inside the document.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/wanted
  $ printf '%s\n' "{\"version\":1,\"id\":\"actual\",\"metadata\":{\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":1},\"events\":[]}" > $SPICE_TEST_DATA_HOME/sessions/wanted/session.json
  $ spice session show wanted | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  spice: session wanted is invalid
  $TESTCASE_ROOT/xdg-data/spice/sessions/wanted/session.json
  document id actual does not match requested id wanted
  [1]

Malformed JSON fails loudly with the document path.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/bad-json
  $ printf '[' > $SPICE_TEST_DATA_HOME/sessions/bad-json/session.json
  $ spice session show bad-json 2>&1 | sed -n '1p'
  spice: session bad-json is invalid
  [1]

Unsupported document versions fail rather than silently migrating.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/v2
  $ printf '%s\n' "{\"version\":2,\"id\":\"v2\",\"metadata\":{\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":1},\"events\":[]}" > $SPICE_TEST_DATA_HOME/sessions/v2/session.json
  $ spice session show v2 | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  spice: session v2 is invalid
  $TESTCASE_ROOT/xdg-data/spice/sessions/v2/session.json
  unsupported session version
  [1]

Documents without the recorded cwd are unsupported and fail loudly; there is no
compatibility repair.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/no-cwd
  $ printf '%s\n' '{"version":1,"id":"no-cwd","metadata":{"title":"Old","status":"active","created_at":1,"updated_at":1},"events":[]}' > $SPICE_TEST_DATA_HOME/sessions/no-cwd/session.json
  $ spice session show no-cwd 2>&1 | sed -n '1p'
  spice: session no-cwd is invalid
  [1]

Old lifecycle event shapes are not accepted as semantic session events.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/old-event
  $ printf '%s\n' "{\"version\":1,\"id\":\"old-event\",\"metadata\":{\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":1},\"events\":[{\"type\":\"archived\"}]}" > $SPICE_TEST_DATA_HOME/sessions/old-event/session.json
  $ spice session show old-event 2>&1 | grep -cE 'archived|session event'
  3
  [1]

Unknown document fields fail loudly.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/unknown-field
  $ printf '%s\n' "{\"version\":1,\"id\":\"unknown-field\",\"metadata\":{\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":1},\"events\":[],\"extra\":true}" > $SPICE_TEST_DATA_HOME/sessions/unknown-field/session.json
  $ spice session show unknown-field 2>&1 | grep -cE 'unknown|extra|Unexpected'
  3
  [1]

One corrupt document never disables discovery: listing reports each corrupt
entry loudly on stderr while still listing valid sessions, and JSON carries the
structured corrupt entries.

  $ SPICE_NOW=90000001 spice session list 2>corrupt.err
  ID      PHASE  AGE     TITLE
  manual  idle   1d ago  Manual
  $ grep '^spice:' corrupt.err | sort | sed -E 's/(session\.json).*/\1/'
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/bad-json/session.json
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/no-cwd/session.json
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/old-event/session.json
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/unknown-field/session.json
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/v2/session.json
  spice: corrupt session document at $TESTCASE_ROOT/xdg-data/spice/sessions/wanted/session.json
  $ spice session list --json 2>/dev/null | grep -o '"corrupt":\['
  "corrupt":[
  $ spice session list --json 2>/dev/null | grep -o '"id":"manual"'
  "id":"manual"

A corrupt target still answers status with a structured error envelope in JSON
mode, and fails loudly in both modes.

  $ spice session show --json no-cwd 2>/dev/null
  {"schema_version":1,"type":"session","session":{"id":"no-cwd","phase":"error","path":"$TESTCASE_ROOT/xdg-data/spice/sessions/no-cwd/session.json","message":"Missing member cwd in session metadata object"}}
  [1]
  $ spice session show --json no-cwd >/dev/null 2>&1; echo "exit=$?"
  exit=1
  $ spice session show no-cwd 2>&1 | sed -n '1p'
  spice: session no-cwd is invalid
  [1]
