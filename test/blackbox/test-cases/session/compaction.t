Manual compaction is a saved-session product flow. It loads an idle session,
asks the configured model for a summary of compactable history, installs a
durable compaction event, and future execution continues from the replacement
transcript instead of provider replay.

The saved document is seeded directly so this test stays focused on compaction.
The live execution suite covers creating these documents through `spice run`.

  $ make_three_turn_session () {
  >   id="$1"
  >   mkdir -p "$SPICE_TEST_DATA_HOME/sessions/$id"
  >   sed -e "s/SESSION_ID/$id/g" -e "s|CWD_PATH|$PWD|g" > "$SPICE_TEST_DATA_HOME/sessions/$id/session.json" <<'JSON'
  > {"version":1,"id":"SESSION_ID","metadata":{"title":"Compact me","status":"active","cwd":"CWD_PATH","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"first prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"first answer"}]}}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}},{"type":"turn_started","turn":{"id":"turn-2","input":{"type":"user","content":[{"type":"text","text":"second prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"second answer"}]}}},{"type":"turn_finished","turn":"turn-2","outcome":{"type":"completed"}},{"type":"turn_started","turn":{"id":"turn-3","input":{"type":"user","content":[{"type":"text","text":"third prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"text","text":"third answer"}]}}},{"type":"turn_finished","turn":"turn-3","outcome":{"type":"completed"}}]}
  > JSON
  > }

  $ scrub_json () {
  >   sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:HASH"/g; s/"projected_input_tokens_estimate":[0-9]+/"projected_input_tokens_estimate":N/g; s/"(before|after|summary_input|summary_output)":[0-9]+/"\1":N/g'
  > }

The top-level compact alias summarizes the first turn and retains the last two
turns under the default compaction policy.

  $ make_three_turn_session compact-live
  $ cat > compact-live.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt","first answer","Summarize the conversation history above","\"tool_choice\":\"none\""],"body_not_contains":["second prompt","third prompt"]},"response":{"id":"resp-compact-live","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Earlier summary: first prompt was answered."}]}]}}
  > JSONL
  $ start_fake_openai compact-live.jsonl compact-live-capture compact-live-port
  $ spice session compact --cwd "$PWD" compact-live
  compacted compact-live summarized=2 retained=4
  $ wait_fake_server

Human status shows the latest compaction without dumping the summary, and
status JSON carries the latest compaction metadata plus context pressure
facts. Status reports summary presence only.

  $ spice session show compact-live | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: compact-live
  title: Compact me
  preview: first prompt
  lifecycle: active
  phase: idle
  events: 10
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  latest_compaction: user_requested summarized=2 retained=4
  $ spice session show --json compact-live | scrub_json | grep -o '"latest_compaction":{[^}]*}'
  "latest_compaction":{"reason":"user_requested","model":"openai/responses:gpt-5.5","summary_present":true,"tokens_estimate":{"before":N,"after":N,"summary_input":N,"summary_output":N}
  $ spice session show --json compact-live | grep -o '"reason":"user_requested"'
  "reason":"user_requested"
  $ spice session show --json compact-live | grep -o '"summary_present":true'
  "summary_present":true
  $ spice session show --json compact-live | grep -c '"summary":'
  1
  $ spice session show --json compact-live | scrub_json | grep -o '"context":{[^}]*}'
  "context":{"projected_input_tokens_estimate":N,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}

Show JSON is the inspection surface and includes the full summary text.

  $ spice session show --json compact-live | grep -o '"summary":"Earlier summary: first prompt was answered."'
  "summary":"Earlier summary: first prompt was answered."

Export keeps the full event history: the pre-compaction events and the
installed compaction.

  $ spice session export compact-live | grep -o '"type":"compaction_installed"'
  "type":"compaction_installed"
  $ spice session export compact-live | grep -o '"text":"first prompt"' | head -1
  "text":"first prompt"
  $ spice session export compact-live | grep -o '"summarized_messages":2'
  "summarized_messages":2
  $ spice session export compact-live | grep -o '"retained_tail_messages":4'
  "retained_tail_messages":4

Future execution uses the compacted replacement transcript. It sees the summary
and retained tail, and it does not use OpenAI previous-response replay from the
pre-compaction responses.

  $ cat > after-compact.jsonl <<'JSONL'
  > {"expect":{"body_contains":["Earlier summary: first prompt was answered.","second prompt","third answer","after compact prompt"],"body_not_contains":["\"previous_response_id\"","first answer"]},"response":{"id":"resp-after-compact","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"post compact answer"}]}]}}
  > JSONL
  $ start_fake_openai after-compact.jsonl after-compact-capture after-compact-port
  $ spice run resume compact-live --cwd "$PWD" "after compact prompt" 2>/dev/null
  post compact answer
  $ wait_fake_server

Repeated compaction builds on the previous summary: the second summary request
replays the first compaction's summary message as part of the new head, never
the already-summarized raw history.

  $ cat > compact-again.jsonl <<'JSONL'
  > {"expect":{"body_contains":["Earlier summary: first prompt was answered.","second prompt","Summarize the conversation history above"],"body_not_contains":["first answer","third prompt","after compact prompt"]},"response":{"id":"resp-compact-again","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Second summary: early history condensed."}]}]}}
  > JSONL
  $ start_fake_openai compact-again.jsonl compact-again-capture compact-again-port
  $ spice session compact --cwd "$PWD" compact-live
  compacted compact-live summarized=3 retained=4
  $ wait_fake_server
  $ spice session show compact-live | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: compact-live
  title: Compact me
  preview: first prompt
  lifecycle: active
  phase: idle
  events: 14
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  latest_compaction: user_requested summarized=3 retained=4
  $ spice session export compact-live | grep -o '"type":"compaction_installed"' | wc -l | tr -d ' '
  2

JSON output exposes the installed compaction as a structured event whose
revision is the saved post-install document revision.

  $ make_three_turn_session compact-json
  $ cat > compact-json.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt","Summarize the conversation history above"]},"response":{"id":"resp-compact-json","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"JSON compact summary."}]}]}}
  > JSONL
  $ start_fake_openai compact-json.jsonl compact-json-capture compact-json-port
  $ spice session compact --json --cwd "$PWD" compact-json | scrub_json
  {"schema_version":1,"type":"compaction.installed","session_id":"compact-json","revision":"sha256:HASH","reason":"user_requested","summary":"JSON compact summary.","model":"openai/responses:gpt-5.5","summarized_messages":2,"retained_tail_messages":4}
  $ wait_fake_server
  $ spice session show --json compact-json | scrub_json | grep -o '"revision":"sha256:HASH"' | head -1
  "revision":"sha256:HASH"

A session without compactable history fails before any provider work and does
not mutate the saved document.

  $ spice session create --id compact-empty
  compact-empty
  $ spice session compact --cwd "$PWD" compact-empty
  spice: conversation already fits within the retained tail; nothing to compact
  [1]
  $ spice session export compact-empty | grep -o '"type":"compaction_installed"' | wc -l | tr -d ' '
  0
  [1]

A waiting session is rejected with a recovery hint before model or credential
work.

The file-mutation editor is model-conditional (a GPT model receives the
apply_patch family, without edit_file/write_file), so this run pins the
string-replace family explicitly; the model stays gpt-5.5 for the fake
OpenAI-Responses backend.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "review",
  >     "matcher": { "type": "path-workspace", "op": "create" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace

  $ cat > blocked-start.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-blocked-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-blocked-1","call_id":"call-write-blocked","name":"write_file","arguments":"{\"path\":\"blocked.txt\",\"contents\":\"blocked contents\"}"}]}}
  > JSONL
  $ start_fake_openai blocked-start.jsonl blocked-capture blocked-port
  $ spice run --cwd "$PWD" --id compact-blocked "write blocked.txt" >/dev/null 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server
  $ spice session compact --cwd "$PWD" compact-blocked
  spice: session is waiting; resolve the waiting before manual compaction
  Hint: see the waiting and its continuation commands: spice session show 'compact-blocked'
  [1]

A stale active session — an active turn with no live owner — is rejected until
the user resumes or records a recovery action.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/compact-stale
  $ sed -e "s|CWD_PATH|$PWD|g" > $SPICE_TEST_DATA_HOME/sessions/compact-stale/session.json <<'JSON'
  > {"version":1,"id":"compact-stale","metadata":{"title":"Stale","status":"active","cwd":"CWD_PATH","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"stale prompt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}}]}
  > JSON
  $ spice session compact --cwd "$PWD" compact-stale
  spice: session has an active turn; manual compaction requires an idle session
  Hint: resume it: spice resume 'compact-stale'
  [1]

An archived session is rejected by its lifecycle — with the restore hint and
before credential work, proven by clearing the credential for the call.

  $ make_three_turn_session compact-archived
  $ spice session archive compact-archived
  compact-archived
  $ OPENAI_API_KEY= spice session compact --cwd "$PWD" compact-archived
  spice: session is archived: compact-archived
  Hint: restore it first: spice session restore 'compact-archived'
  [1]

A malformed provider response fails the compaction and does not mutate the
saved session.

  $ make_three_turn_session compact-malformed
  $ cat > compact-malformed.jsonl <<'JSONL'
  > {"response":{"id":"resp-malformed","status":"completed","model":"gpt-5.5","output":"not-an-array"}}
  > JSONL
  $ start_fake_openai compact-malformed.jsonl compact-malformed-capture compact-malformed-port
  $ spice session compact --cwd "$PWD" compact-malformed
  spice: OpenAI response produced no assistant parts
  [1]
  $ wait_fake_server
  $ spice session export compact-malformed | grep -o '"type":"compaction_installed"' | wc -l | tr -d ' '
  0
  [1]

A summary failure does not mutate the saved session.

  $ make_three_turn_session compact-fail
  $ cat > compact-fail.jsonl <<'JSONL'
  > {"http":{"status":400,"body":{"error":{"message":"summary rejected","type":"invalid_request_error"}}}}
  > JSONL
  $ start_fake_openai compact-fail.jsonl compact-fail-capture compact-fail-port
  $ spice session compact --cwd "$PWD" compact-fail
  spice: OpenAI request failed
  [1]
  $ wait_fake_server
  $ spice session export compact-fail | grep -o '"type":"compaction_installed"' | wc -l | tr -d ' '
  0
  [1]
