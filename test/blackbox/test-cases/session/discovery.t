Session discovery renders recognizable rows: title falls back to the
first-prompt preview, recency is bucketed, and listing is cwd-scoped.

Previews derive from the first user prompt: whitespace collapses to single
spaces and long prompts truncate at 80 bytes with an ellipsis. Untitled rows
fall back to the preview.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/preview
  $ cat > $SPICE_TEST_DATA_HOME/sessions/preview/session.json <<JSON
  > {"version":1,"id":"preview","metadata":{"cwd":"$PWD","status":"active","created_at":1,"updated_at":199880000},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"one two   three\nfour five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}}]}
  > JSON
  $ spice session show preview | grep '^preview'
  preview: one two three four five six seven eight nine ten eleven twelve thirteen fourteen…
  $ spice session list --json 2>/dev/null | grep -o '"preview":"[^"]*"'
  "preview":"one two three four five six seven eight nine ten eleven twelve thirteen fourteen…"

Search matches the preview — exactly what the row shows, so text beyond the
truncation cut does not match.

  $ SPICE_NOW=200000000 spice session search eleven
  ID       PHASE   AGE     TITLE
  preview  active  2m ago  one two three four five six seven eight nine ten eleven twelve thirteen fourteen…
  $ spice session search sixteen
  ID  PHASE  AGE  TITLE

AGE buckets render minutes, hours, and days against the injected clock.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/hours $SPICE_TEST_DATA_HOME/sessions/days
  $ cat > $SPICE_TEST_DATA_HOME/sessions/hours/session.json <<JSON
  > {"version":1,"id":"hours","metadata":{"cwd":"$PWD","title":"Hours","status":"active","created_at":1,"updated_at":192800000},"events":[]}
  > JSON
  $ cat > $SPICE_TEST_DATA_HOME/sessions/days/session.json <<JSON
  > {"version":1,"id":"days","metadata":{"cwd":"$PWD","title":"Days","status":"active","created_at":1,"updated_at":1},"events":[]}
  > JSON
  $ SPICE_NOW=200000000 spice session list
  ID       PHASE   AGE     TITLE
  preview  active  2m ago  one two three four five six seven eight nine ten eleven twelve thirteen fourteen…
  hours    idle    2h ago  Hours
  days     idle    2d ago  Days

Sessions recorded in another directory are hidden by default; --all widens the
scope and adds the CWD column.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/remote
  $ cat > $SPICE_TEST_DATA_HOME/sessions/remote/session.json <<'JSON'
  > {"version":1,"id":"remote","metadata":{"cwd":"/other/place","title":"Remote","status":"active","created_at":1,"updated_at":1},"events":[]}
  > JSON
  $ spice session list | grep '^remote' || echo hidden
  hidden
  $ SPICE_NOW=200000000 spice session list --all
  ID       PHASE   AGE     CWD                                                                                                                                 TITLE
  preview  active  2m ago  $TESTCASE_ROOT  one two three four five six seven eight nine ten eleven twelve thirteen fourteen…
  hours    idle    2h ago  $TESTCASE_ROOT  Hours
  remote   idle    2d ago  /other/place                                                                                                                        Remote
  days     idle    2d ago  $TESTCASE_ROOT  Days

The default limit is 25, the human output says when it truncated, and
--limit 0 is unbounded.

  $ mkdir bulk && cd bulk
  $ for i in $(seq 1 26); do spice session create --id "bulk-$i" >/dev/null; done
  $ spice session list 2>notice.err | tail -n +2 | wc -l | tr -d ' '
  25
  $ cat notice.err
  spice: session list truncated; use --limit 0 to show all
  $ spice session list --limit 0 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
  26
  $ cd ..
