Rewind forks a saved session at a turn boundary. The child is a new session
whose transcript is the parent's prefix up to the chosen turn; the parent is
left untouched. Rewind is transcript-only here — no workspace revert.

Sessions are seeded directly so the test stays focused on the rewind transform.

  $ make_two_turn_session () {
  >   id="$1"
  >   mkdir -p "$SPICE_TEST_DATA_HOME/sessions/$id"
  >   sed -e "s/SESSION_ID/$id/g" -e "s|CWD_PATH|$PWD|g" > "$SPICE_TEST_DATA_HOME/sessions/$id/session.json" <<'JSON'
  > {"version":1,"id":"SESSION_ID","metadata":{"title":"Rewind me","status":"active","cwd":"CWD_PATH","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"first prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"first answer"}]}}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}},{"type":"turn_started","turn":{"id":"turn-2","input":{"type":"user","content":[{"type":"text","text":"second prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"second answer"}]}}},{"type":"turn_finished","turn":"turn-2","outcome":{"type":"completed"}}]}
  > JSON
  > }

  $ make_three_turn_session () {
  >   id="$1"
  >   mkdir -p "$SPICE_TEST_DATA_HOME/sessions/$id"
  >   sed -e "s/SESSION_ID/$id/g" -e "s|CWD_PATH|$PWD|g" > "$SPICE_TEST_DATA_HOME/sessions/$id/session.json" <<'JSON'
  > {"version":1,"id":"SESSION_ID","metadata":{"title":"Rewind me","status":"active","cwd":"CWD_PATH","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"first prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"first answer"}]}}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}},{"type":"turn_started","turn":{"id":"turn-2","input":{"type":"user","content":[{"type":"text","text":"second prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"second answer"}]}}},{"type":"turn_finished","turn":"turn-2","outcome":{"type":"completed"}},{"type":"turn_started","turn":{"id":"turn-3","input":{"type":"user","content":[{"type":"text","text":"third prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"third answer"}]}}},{"type":"turn_finished","turn":"turn-3","outcome":{"type":"completed"}}]}
  > JSON
  > }

Rewinding just before the second turn keeps only the first turn. The child is a
fresh session with the parent's prefix and a Forked_from lineage; the parent is
unchanged.

  $ make_two_turn_session basic
  $ spice session rewind basic --to-turn turn-2 --id basic-child
  basic-child
  rewound basic: kept 1 dropped 1
  $ spice session show basic-child | sed -E 's/revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/; s/(created|updated)_at: [0-9]+/\1_at: $TIME/'
  id: basic-child
  title: -
  preview: first prompt
  lifecycle: active
  phase: idle
  events: 3
  forked_from: basic events=3
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH

The child transcript is exactly the first turn: the second turn's events are
gone.

  $ spice session export basic-child | grep -o '"text":"first prompt"'
  "text":"first prompt"
  $ spice session export basic-child | grep -c '"text":"second prompt"'
  0
  [1]

The parent is untouched: it still has both turns.

  $ spice session show basic | grep '^events:'
  events: 6

The --after edge keeps the named turn and drops the rest. Rewinding after the
first turn matches rewinding before the second.

  $ spice session rewind basic --to-turn turn-1 --after --id after-child
  after-child
  rewound basic: kept 1 dropped 1
  $ spice session show after-child | grep '^events:'
  events: 3

Rewinding before the first turn yields an empty-log child, equivalent to a fresh
session in the same cwd.

  $ spice session rewind basic --to-turn turn-1 --id empty-child
  empty-child
  rewound basic: kept 0 dropped 2
  $ spice session show empty-child | grep '^events:'
  events: 0

Rewinding past a compaction un-compacts by construction. Install a compaction
that summarizes the first turn, then rewind to a boundary before it: the child's
transcript is the raw pre-compaction events, with no compaction installed.

  $ make_three_turn_session compacted
  $ cat > compacted.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt","Summarize the conversation history above"]},"response":{"id":"resp-compacted","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Earlier summary: first turn condensed."}]}]}}
  > JSONL
  $ start_fake_openai compacted.jsonl compacted-capture compacted-port
  $ spice session compact --cwd "$PWD" compacted
  compacted compacted summarized=2 retained=4
  $ wait_fake_server

The compacted parent carries the installed compaction over its full history.

  $ spice session export compacted | grep -c '"type":"compaction_installed"'
  1
  $ spice session show compacted | grep '^latest_compaction:'
  latest_compaction: user_requested summarized=2 retained=4

Rewinding before the third turn drops the third turn and the trailing
compaction, reviving the pre-compaction transcript of the first two turns.

  $ spice session rewind compacted --to-turn turn-3 --id uncompacted
  uncompacted
  rewound compacted: kept 2 dropped 1
  $ spice session export uncompacted | grep -c '"type":"compaction_installed"'
  0
  [1]
  $ spice session export uncompacted | grep -o '"text":"first prompt"'
  "text":"first prompt"
  $ spice session export uncompacted | grep -o '"text":"second prompt"'
  "text":"second prompt"
  $ spice session export uncompacted | grep -c '"text":"third prompt"'
  0
  [1]
  $ spice session show uncompacted | sed -E 's/revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/; s/(created|updated)_at: [0-9]+/\1_at: $TIME/'
  id: uncompacted
  title: -
  preview: first prompt
  lifecycle: active
  phase: idle
  events: 6
  forked_from: compacted events=6
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH

The pre-compaction parent is untouched: it still carries the compaction.

  $ spice session export compacted | grep -c '"type":"compaction_installed"'
  1

An unknown turn id is a recoverable input error: the command reports it and
writes no child.

  $ spice session rewind basic --to-turn turn-nope --id nope-child
  spice: turn is not in the session: turn-nope
  [1]
  $ test -e $SPICE_TEST_DATA_HOME/sessions/nope-child/session.json && echo written || echo absent
  absent

The two edge flags are mutually exclusive.

  $ spice session rewind basic --to-turn turn-1 --before --after --id both-child
  spice: use at most one of --before or --after
  [2]
