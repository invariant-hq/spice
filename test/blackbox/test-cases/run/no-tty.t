Continuation input may be read from stdin with `-`, and empty stdin is always
a usage error. The empty-prompt edge lives in errors.t; these are the
continuation edges, each against a real pending blocker so only the stdin
validation can fail.

  $ make_session () {
  >   mkdir -p "$SPICE_TEST_DATA_HOME/sessions/$1"
  >   cat > "$SPICE_TEST_DATA_HOME/sessions/$1/session.json"
  > }

  $ make_session blocked-question <<JSON
  > {"version":1,"id":"blocked-question","metadata":{"cwd":"$PWD","title":"Blocked question","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Deploy"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[{"name":"ask_user","input_schema":{"type":"object"}}],"host_tools":["ask_user"],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"question-1","name":"ask_user","input":{"question":"Which region?"}}}]}}}]}
  > JSON

  $ make_session blocked-perm <<JSON
  > {"version":1,"id":"blocked-perm","metadata":{"cwd":"$PWD","title":"Blocked permission","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Use the tool"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-1","name":"write_file","input":{"path":"blocked.txt","contents":"blocked"}}}]}}},{"type":"permission_requested","request":{"id":"permission-1","turn":"turn-1","tool_call":{"id":"call-1","name":"write_file","input":{"path":"blocked.txt","contents":"blocked"}},"request":{"version":3,"items":[{"access":{"type":"custom","name":"write_file"}}]},"reasons":[{"access":{"type":"custom","name":"write_file"},"reason":{"kind":"unmatched"}}]}}]}
  > JSON

  $ make_session crashed-tool <<JSON
  > {"version":1,"id":"crashed-tool","metadata":{"cwd":"$PWD","title":"Crashed tool","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Write crash.txt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-write-crash","name":"write_file","input":{"path":"crash.txt","contents":"crashed contents"}}}]}}},{"type":"tool_claim_started","execution":{"id":"tool_exec-crashed","turn":"turn-1","call":{"id":"call-write-crash","name":"write_file","input":{"path":"crash.txt","contents":"crashed contents"}}}}]}
  > JSON

An empty stdin answer is rejected before any session mutation.

  $ printf '' | spice run reply blocked-question --cwd "$PWD" --question question-1 --answer -
  spice: stdin answer must not be empty
  [2]

An empty stdin denial message is rejected.

  $ printf '' | spice run reply blocked-perm --cwd "$PWD" --deny permission-1 --message -
  spice: stdin message must not be empty
  [2]

An empty stdin interruption reason is rejected.

  $ printf '' | spice run reply crashed-tool --cwd "$PWD" --tool-interrupted tool_exec-crashed --reason -
  spice: stdin reason must not be empty
  [2]

The rejected continuations left the sessions untouched and still waiting.

  $ spice session show --json blocked-question | grep -o '"phase":"waiting"'
  "phase":"waiting"
  $ spice session show --json blocked-perm | grep -o '"phase":"waiting"'
  "phase":"waiting"
  $ spice session show --json crashed-tool | grep -o '"phase":"waiting"'
  "phase":"waiting"
