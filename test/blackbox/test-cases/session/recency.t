Saved metadata updates participate in session recency.

Seeded sessions list by their persisted updated_at timestamp.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/older $SPICE_TEST_DATA_HOME/sessions/newer
  $ printf '%s\n' "{\"version\":1,\"id\":\"older\",\"metadata\":{\"title\":\"Older\",\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":1},\"events\":[]}" > $SPICE_TEST_DATA_HOME/sessions/older/session.json
  $ printf '%s\n' "{\"version\":1,\"id\":\"newer\",\"metadata\":{\"title\":\"Newer\",\"status\":\"active\",\"cwd\":\"$PWD\",\"created_at\":1,\"updated_at\":2},\"events\":[]}" > $SPICE_TEST_DATA_HOME/sessions/newer/session.json
  $ spice session list --json | grep -o '"id":"[^"]*"' | head -2
  "id":"newer"
  "id":"older"

Renaming the older session saves it with a fresh updated_at, making it the
newest resumable document without relying on exact wall-clock values.

  $ spice session rename older "Renamed older"
  older
  $ spice session list --json | grep -o '"id":"[^"]*"' | head -2
  "id":"older"
  "id":"newer"
