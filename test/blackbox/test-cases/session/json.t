Session JSON output is script-friendly and carries explicit schema/type
envelopes.

Create emits the full session summary with a durable revision token.

  $ spice session create --json --id alpha --title Alpha | sed -E 's/sha256:[0-9a-f]+(:[0-9]+)?/sha256:$HASH/g; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"alpha","title":"Alpha","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"}}

Show uses the same JSON shape; the old info alias is gone.

  $ spice session show --json alpha | sed -E 's/sha256:[0-9a-f]+(:[0-9]+)?/sha256:$HASH/g; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"alpha","title":"Alpha","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":null,"waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":0,"basis":"estimate","context_window":null,"auto_compaction_limit":null}}
  $ spice session info --json alpha 2>&1 | head -1
  Usage: spice session [--help] COMMAND …
  [124]

List JSON is ordered by newest update first and includes per-document revisions.

  $ spice session create --id beta --title Beta
  beta
  $ spice session create --id gamma --title Gamma
  gamma
  $ spice session list --json | sed -E 's/sha256:[0-9a-f]+(:[0-9]+)?/sha256:$HASH/g; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"sessions","sessions":[{"id":"gamma","title":"Gamma","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"},{"id":"beta","title":"Beta","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"},{"id":"alpha","title":"Alpha","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"}]}

The list limit applies after lifecycle filtering and before output rendering.

  $ spice session list --json --limit 2 | sed -E 's/sha256:[0-9a-f]+(:[0-9]+)?/sha256:$HASH/g; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"sessions","sessions":[{"id":"gamma","title":"Gamma","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"},{"id":"beta","title":"Beta","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"}]}

Search JSON reports the query and the matched session summaries.

  $ spice session search --json alp | sed -E 's/sha256:[0-9a-f]+(:[0-9]+)?/sha256:$HASH/g; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"session_search","query":"alp","sessions":[{"id":"alpha","title":"Alpha","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH"}]}

Fork lineage is represented structurally in JSON.

  $ spice session fork alpha --id alpha-child --title Child
  alpha-child
  $ spice session show --json alpha-child | sed -E 's/sha256:[0-9a-f]+(:[0-9]+)?/sha256:$HASH/g; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"alpha-child","title":"Child","preview":null,"lifecycle":"active","phase":"idle","forked_from":{"parent":"alpha","copied_events":0},"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":null,"waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":0,"basis":"estimate","context_window":null,"auto_compaction_limit":null}}
