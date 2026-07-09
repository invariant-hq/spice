Session status JSON exposes the stable idle, active, and waiting phases.

Idle sessions have no active turn.

  $ spice session create --id idle --title Idle
  idle
  $ spice session show --json idle | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"idle","title":"Idle","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":null,"waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":0,"basis":"estimate","context_window":null,"auto_compaction_limit":null}}

An unfinished active turn with no live owner is reported as active.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/stale
  $ cat > $SPICE_TEST_DATA_HOME/sessions/stale/session.json <<'JSON'
  > {"version":1,"id":"stale","metadata":{"cwd":"/","title":"Stale","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Continue"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}}]}
  > JSON
  $ spice session show --json stale | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"stale","title":"Stale","preview":"Continue","lifecycle":"active","phase":"active","forked_from":null,"event_count":1,"active_turn":"turn-1","cwd":"/","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":"openai/responses:gpt-5","last_outcome":null,"waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":2,"basis":"estimate","context_window":null,"auto_compaction_limit":null}}

Pending permission requests are reported as waiting.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/blocked
  $ cat > $SPICE_TEST_DATA_HOME/sessions/blocked/session.json <<'JSON'
  > {"version":1,"id":"blocked","metadata":{"cwd":"/","title":"Blocked","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Use the tool"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-1","name":"review_tool","input":{}}}]}}},{"type":"permission_requested","request":{"id":"permission-1","turn":"turn-1","tool_call":{"id":"call-1","name":"review_tool","input":{}},"request":{"version":2,"items":[{"access":{"type":"custom","kind":"write","name":"review_tool"}}]},"asked":[{"type":"custom","kind":"write","name":"review_tool"}]}}]}
  > JSON
  $ spice session show --json blocked | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"blocked","title":"Blocked","preview":"Use the tool","lifecycle":"active","phase":"waiting","forked_from":null,"event_count":3,"active_turn":"turn-1","cwd":"/","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":"openai/responses:gpt-5","last_outcome":null,"waiting":{"kind":"permission","permission_id":"permission-1","turn":"turn-1","tool_call_id":"call-1","tool":"review_tool","mode":"default","reviewed":[{"access":{"type":"custom","kind":"write","name":"review_tool"},"explanation":{"kind":"needs_review"}}]}},"latest_compaction":null,"context":{"projected_input_tokens_estimate":67,"basis":"estimate","context_window":null,"auto_compaction_limit":null}}

Human status prints the same facts and shell-quoted continuation commands as
waiting exec output; active sessions get the resume command.

  $ spice session show idle | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: idle
  title: Idle
  preview: -
  lifecycle: active
  phase: idle
  events: 0
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  $ spice session show stale | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: stale
  title: Stale
  preview: Continue
  lifecycle: active
  phase: active
  events: 1
  forked_from: -
  cwd: /
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  active turn turn-1 has no live owner
  resume: spice resume 'stale'
  $ spice session show blocked | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: blocked
  title: Blocked
  preview: Use the tool
  lifecycle: active
  phase: waiting
  events: 3
  forked_from: -
  cwd: /
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  waiting: permission permission-1 tool=review_tool turn=turn-1 call=call-1
  mode: default
  accesses:
  - write custom review_tool  [review: no rule or grant]
  allow once: spice run reply 'blocked' --allow 'permission-1'
  allow session: spice run reply 'blocked' --allow-session 'permission-1'
  deny: spice run reply 'blocked' --deny 'permission-1'
  deny with message: spice run reply 'blocked' --deny 'permission-1' --message TEXT|-

Non-active lifecycle decorates the phase token. Archiving is gated to idle
sessions — a session with an active turn cannot be archived — so archived and
deleted normally decorate only idle status. Tombstones stay inspectable with
no next step.

  $ spice session archive blocked
  spice: session already has active turn: turn-1
  [1]
  $ spice session create --id tombstone --title Tombstone
  tombstone
  $ spice session archive tombstone
  tombstone
  $ spice session show tombstone | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: tombstone
  title: Tombstone
  preview: -
  lifecycle: archived
  phase: idle
  events: 0
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  $ spice session restore tombstone
  tombstone
  $ spice session delete --yes tombstone
  tombstone
  $ spice session show tombstone | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: tombstone
  title: Tombstone
  preview: -
  lifecycle: deleted
  phase: idle
  events: 0
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  $ spice session show --json tombstone | grep -o '"phase":"idle","lifecycle":"deleted"'
  [1]

A hand-edited archived session with a stranded active turn still
renders honestly: the phase token carries the lifecycle, and the next step is
restore, not a continuation command the lifecycle gate would reject.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/archived-blocked
  $ cat > $SPICE_TEST_DATA_HOME/sessions/archived-blocked/session.json <<'JSON'
  > {"version":1,"id":"archived-blocked","metadata":{"cwd":"/","title":"Archived blocked","status":"archived","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Use the tool"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-1","name":"review_tool","input":{}}}]}}},{"type":"permission_requested","request":{"id":"permission-1","turn":"turn-1","tool_call":{"id":"call-1","name":"review_tool","input":{}},"request":{"version":2,"items":[{"access":{"type":"custom","kind":"write","name":"review_tool"}}]},"asked":[{"type":"custom","kind":"write","name":"review_tool"}]}}]}
  > JSON
  $ spice session show archived-blocked | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: archived-blocked
  title: Archived blocked
  preview: Use the tool
  lifecycle: archived
  phase: waiting
  events: 3
  forked_from: -
  cwd: /
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  waiting: permission permission-1 tool=review_tool turn=turn-1 call=call-1
  restore first: spice session restore 'archived-blocked'
  $ spice session show --json archived-blocked | grep -o '"phase":"waiting","lifecycle":"archived"'
  [1]

Workflow sidecars are projected through session status and show, not standalone
plan or todo commands.

  $ spice session create --id workflow --title Workflow
  workflow
  $ mkdir -p $SPICE_TEST_DATA_HOME/plans/workflow $SPICE_TEST_DATA_HOME/todos
  $ cat > $SPICE_TEST_DATA_HOME/plans/workflow/plan-1.json <<'JSON'
  > {"id":"plan-1","source":{"session":"workflow","turn":"turn-plan","tool_call_id":"call-plan"},"title":"Plan","body":"Do the work","status":{"type":"proposed"},"created_at":1}
  > JSON
  $ cat > $SPICE_TEST_DATA_HOME/todos/workflow.json <<'JSON'
  > [{"id":"todo-1","owner":"main","content":"Inspect code","status":"in_progress","priority":"high","position":0},{"id":"todo-2","owner":"main","content":"Update docs","status":"pending","priority":"medium","position":1}]
  > JSON
  $ spice session show --json workflow | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"workflow","title":"Workflow","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":null,"waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":0,"basis":"estimate","context_window":null,"auto_compaction_limit":null},"workflow":{"plans":[{"id":"plan-1","source":{"session":"workflow","turn":"turn-plan","tool_call_id":"call-plan"},"title":"Plan","body":"Do the work","status":{"type":"proposed"},"created_at":$TIME}],"todos":[{"id":"todo-1","owner":"main","content":"Inspect code","status":"in_progress","priority":"high","position":0},{"id":"todo-2","owner":"main","content":"Update docs","status":"pending","priority":"medium","position":1}],"subagents":[]}}
  $ spice session show --json workflow | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"workflow","title":"Workflow","preview":null,"lifecycle":"active","phase":"idle","forked_from":null,"event_count":0,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":null,"waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":0,"basis":"estimate","context_window":null,"auto_compaction_limit":null},"workflow":{"plans":[{"id":"plan-1","source":{"session":"workflow","turn":"turn-plan","tool_call_id":"call-plan"},"title":"Plan","body":"Do the work","status":{"type":"proposed"},"created_at":$TIME}],"todos":[{"id":"todo-1","owner":"main","content":"Inspect code","status":"in_progress","priority":"high","position":0},{"id":"todo-2","owner":"main","content":"Update docs","status":"pending","priority":"medium","position":1}],"subagents":[]}}

Obsolete unscoped plan files fail loudly instead of being silently ignored.

  $ cat > $SPICE_TEST_DATA_HOME/plans/legacy.json <<'JSON'
  > {"id":"legacy","source":{"session":"workflow","turn":"turn-plan","tool_call_id":"call-plan"},"body":"Old layout","status":{"type":"proposed"},"created_at":1}
  > JSON
  $ spice session show --json workflow 2>&1
  spice: $TESTCASE_ROOT/xdg-data/spice/plans/legacy.json: unscoped plan artifacts are unsupported; expected plans/<session>/<plan>.json
  [1]
