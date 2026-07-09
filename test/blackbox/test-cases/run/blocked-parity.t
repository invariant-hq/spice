The session status snapshot and the exec terminal waiting event expose the
identical waiting object, field for field, for every waiting kind. The same
extraction runs on both surfaces and the shell equality assertion fails this
test if they ever drift. No fake provider listens: a waiting resume must
report the waiting boundary before any model request.

  $ make_session () {
  >   mkdir -p "$SPICE_TEST_DATA_HOME/sessions/$1"
  >   cat > "$SPICE_TEST_DATA_HOME/sessions/$1/session.json"
  > }

A pending permission request.

  $ make_session blocked-perm <<JSON
  > {"version":1,"id":"blocked-perm","metadata":{"cwd":"$PWD","title":"Blocked permission","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Use the tool"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-1","name":"write_file","input":{"path":"blocked.txt","contents":"blocked"}}}]}}},{"type":"permission_requested","request":{"id":"permission-1","turn":"turn-1","tool_call":{"id":"call-1","name":"write_file","input":{"path":"blocked.txt","contents":"blocked"}},"request":{"version":2,"items":[{"access":{"type":"custom","kind":"write","name":"write_file"}}]},"asked":[{"type":"custom","kind":"write","name":"write_file"}]}}]}
  > JSON

  $ spice session show --json blocked-perm | grep -o '"waiting":{[^}]*}' >perm.status
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume blocked-perm --cwd "$PWD" --json >perm.out 2>perm.err; echo exit:$?
  exit:3
  $ grep -o '"waiting":{[^}]*}' perm.out >perm.exec
  $ cat perm.status
  "waiting":{"kind":"permission","permission_id":"permission-1","turn":"turn-1","tool_call_id":"call-1","tool":"write_file","mode":"default","reviewed":[{"access":{"type":"custom","kind":"write","name":"write_file"}
  $ [ "$(cat perm.status)" = "$(cat perm.exec)" ] && echo identical
  identical

A pending host-handled user question, including the decoded question text.

  $ make_session blocked-question <<JSON
  > {"version":1,"id":"blocked-question","metadata":{"cwd":"$PWD","title":"Blocked question","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Deploy"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":["ask_user"]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"question-1","name":"ask_user","input":{"question":"Which region?"}}}]}}}]}
  > JSON

  $ spice session show --json blocked-question | grep -o '"waiting":{[^}]*}' >question.status
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume blocked-question --cwd "$PWD" --json >question.out 2>question.err; echo exit:$?
  exit:3
  $ grep -o '"waiting":{[^}]*}' question.out >question.exec
  $ cat question.status
  "waiting":{"kind":"host_tool","turn":"turn-1","tool_call_id":"question-1","tool":"ask_user","question":"Which region?"}
  $ [ "$(cat question.status)" = "$(cat question.exec)" ] && echo identical
  identical

A claimed-but-unfinished tool claim.

  $ make_session crashed-tool <<JSON
  > {"version":1,"id":"crashed-tool","metadata":{"cwd":"$PWD","title":"Crashed tool","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Write crash.txt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-write-crash","name":"write_file","input":{"path":"crash.txt","contents":"crashed contents"}}}]}}},{"type":"tool_claim_started","execution":{"id":"tool_exec-crashed","turn":"turn-1","call":{"id":"call-write-crash","name":"write_file","input":{"path":"crash.txt","contents":"crashed contents"}}}}]}
  > JSON

  $ spice session show --json crashed-tool | grep -o '"waiting":{[^}]*}' >crashed.status
  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume crashed-tool --cwd "$PWD" --json >crashed.out 2>crashed.err; echo exit:$?
  exit:3
  $ grep -o '"waiting":{[^}]*}' crashed.out >crashed.exec
  $ cat crashed.status
  "waiting":{"kind":"tool_claim","claim_id":"tool_exec-crashed","turn":"turn-1","tool_call_id":"call-write-crash","tool":"write_file"}
  $ [ "$(cat crashed.status)" = "$(cat crashed.exec)" ] && echo identical
  identical

JSON mode keeps stdout machine-readable: one JSON object per line, human
diagnostics on stderr only.

  $ grep -v '^{' perm.out || echo stdout-pure
  stdout-pure
  $ grep -v '^{' question.out || echo stdout-pure
  stdout-pure
  $ grep -v '^{' crashed.out || echo stdout-pure
  stdout-pure
  $ cat perm.err
  spice: session blocked
