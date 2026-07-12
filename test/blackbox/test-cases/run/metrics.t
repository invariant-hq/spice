Headless JSON execution reports a metrics projection derived from durable
session events, not a parallel accounting path.

Text mode is unchanged even when the provider reports usage.

  $ cat > text-usage.jsonl <<'JSONL'
  > {"expect":{"body_contains":["text metrics prompt"]},"response":{"id":"resp-text-metrics","status":"completed","model":"gpt-5.5","usage":{"input_tokens":3,"output_tokens":2},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"text metrics final"}]}]}}
  > JSONL

  $ start_fake_openai text-usage.jsonl text-usage-capture text-usage-port
  $ spice run --cwd "$PWD" --id text-metrics "text metrics prompt"
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  text metrics final
  spice: session saved; resume with: spice resume 'text-metrics'
  $ wait_fake_server

JSON mode includes five-lane usage summed across provider responses, terminal
turn count, finished tool-call count, failed tool-call count, and per-tool
counts. The shell call fails (here the restricted sandbox refuses it; with
enforcement available the command itself exits 7), and the failed call is
counted in tool_failures either way.

  $ cat > tool-metrics.jsonl <<'JSONL'
  > {"expect":{"body_contains":["tool metrics prompt","\"name\":\"shell\""]},"response":{"id":"resp-tool-metrics-1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":4},"output_tokens":6,"output_tokens_details":{"reasoning_tokens":2}},"output":[{"type":"function_call","id":"item-shell-metrics","call_id":"call-shell-metrics","name":"shell","arguments":"{\"command\":\"printf out; printf err >&2; exit 7\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-shell-metrics"]},"response":{"id":"resp-tool-metrics-2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":20,"input_tokens_details":{"cached_tokens":5},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"tool metrics final"}]}]}}
  > JSONL

  $ start_fake_openai tool-metrics.jsonl tool-metrics-capture tool-metrics-port
  $ spice run --cwd "$PWD" --json --permission bypass --id tool-metrics "tool metrics prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"tool_claim_id":"tool_exec:[0-9a-f]+"/"tool_claim_id":"tool_exec:$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$TIME/g'
  spice: session saved; resume with: spice resume 'tool-metrics'
  {"schema_version":1,"type":"run.started","permission":{"review":"bypass"},"sandbox":{"mode":"danger-full-access","read":"all","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"tool-metrics","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"tool-metrics","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"tool.started","session_id":"tool-metrics","turn_id":"turn_$ID","tool_call_id":"call-shell-metrics","tool_claim_id":"tool_exec:$ID","tool":"shell"}
  {"schema_version":1,"type":"tool.finished","session_id":"tool-metrics","turn_id":"turn_$ID","tool_call_id":"call-shell-metrics","tool_claim_id":"tool_exec:$ID","tool":"shell","status":"failed","error":{"kind":"failed","message":"command exited with status 7"},"truncated":false,"process":{"exit_status":7,"duration_ms":$TIME,"stdout":{"kind":"complete"},"stderr":{"kind":"complete"},"sandbox":{"kind":"not_requested"}}}
  {"schema_version":1,"type":"turn.finished","session_id":"tool-metrics","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"tool metrics final","metrics":{"usage":{"input":21,"output":8,"reasoning":5,"cache_read":9,"cache_write":0},"responses":2,"turns":1,"tool_calls":1,"tool_failures":1,"tool_rejections":0,"tool_calls_by_name":[{"name":"shell","count":1}],"permission_denials":0},"duration_ms":$TIME}
  $ wait_fake_server

Blocked runs report spend so far. The GPT family ships apply_patch rather than
write_file, so pin the string-replace editor family to keep write_file in the
catalog for the mutating-tool cases below.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<'JSON'
  > { "permission": { "rules": [
  >   { "action": "review",
  >     "matcher": { "type": "path-workspace", "op": "create" } } ] } }
  > JSON
  $ spice config set tools.editor string-replace

  $ cat > blocked-metrics.jsonl <<'JSONL'
  > {"expect":{"body_contains":["blocked metrics prompt","\"name\":\"write_file\""]},"response":{"id":"resp-blocked-metrics","status":"completed","model":"gpt-5.5","usage":{"input_tokens":9,"input_tokens_details":{"cached_tokens":1},"output_tokens":3},"output":[{"type":"function_call","id":"item-blocked-metrics","call_id":"call-blocked-metrics","name":"write_file","arguments":"{\"path\":\"blocked-metrics.txt\",\"contents\":\"blocked\"}"}]}}
  > JSONL

  $ start_fake_openai blocked-metrics.jsonl blocked-metrics-capture blocked-metrics-port
  $ spice run --cwd "$PWD" --json --id blocked-metrics "blocked metrics prompt" >blocked-metrics.out 2>blocked-metrics.err; echo exit:$?
  exit:3
  $ wait_fake_server
  $ sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"permission_id":"perm:[^"]+"/"permission_id":"perm:$ID"/g; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"turn":"turn_[^"]+"/"turn":"turn_$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$TIME/g' blocked-metrics.out | grep '"type":"session.waiting"'
  {"schema_version":1,"type":"session.waiting","session_id":"blocked-metrics","revision":"sha256:$HASH","waiting":{"kind":"permission","permission_id":"perm:$ID","turn":"turn_$ID","tool_call_id":"call-blocked-metrics","tool":"write_file","review":"default","reviewed":[{"access":{"type":"path","op":"create","scope":"workspace","root_key":"$TESTCASE_ROOT","relative":"blocked-metrics.txt"},"explanation":{"kind":"needs_review_by_rule","rule_id":"a893d6c9785e","rule_source":"user"},"change":{"diff":"--- /dev/null\n+++ $TESTCASE_ROOT/blocked-metrics.txt\n@@ -0,0 +1,1 @@\n+blocked\n\\ No newline at end of file\n","additions":1,"removals":0}}]},"metrics":{"usage":{"input":8,"output":3,"reasoning":0,"cache_read":1,"cache_write":0},"responses":1,"turns":0,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  $ cat blocked-metrics.err
  spice: session blocked

Denied permissions are counted: the deny continuation finishes the turn with
permission_denials reflected in the final metrics, and the denied call is not
counted as an executed tool call.

  $ cat > deny-metrics.jsonl <<'JSONL'
  > {"expect":{"body_contains":["deny metrics prompt","\"name\":\"write_file\""]},"response":{"id":"resp-deny-metrics-1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":5,"output_tokens":2},"output":[{"type":"function_call","id":"item-deny-metrics","call_id":"call-deny-metrics","name":"write_file","arguments":"{\"path\":\"deny-metrics.txt\",\"contents\":\"denied\"}"}]}}
  > JSONL

  $ start_fake_openai deny-metrics.jsonl deny-capture-start deny-port-start
  $ spice run --cwd "$PWD" --json --id deny-metrics "deny metrics prompt" >deny-block.out 2>deny-block.err; echo exit:$?
  exit:3
  $ wait_fake_server

  $ permission_id=$(spice session show --json deny-metrics | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > deny-finish.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-deny-metrics"]},"response":{"id":"resp-deny-metrics-2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":8,"input_tokens_details":{"cached_tokens":2},"output_tokens":4},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"deny metrics final"}]}]}}
  > JSONL
  $ start_fake_openai deny-finish.jsonl deny-capture-finish deny-port-finish
  $ spice run reply deny-metrics --cwd "$PWD" --json --deny "$permission_id" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$TIME/g' | grep '"type":"turn.finished"'
  spice: session saved; resume with: spice resume 'deny-metrics'
  {"schema_version":1,"type":"turn.finished","session_id":"deny-metrics","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"deny metrics final","metrics":{"usage":{"input":11,"output":6,"reasoning":0,"cache_read":2,"cache_write":0},"responses":2,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":1},"duration_ms":$TIME}
  $ wait_fake_server

Rejected tool calls are counted separately from executed failures: an
input-validation error answers the model without claiming an execution, so it
increments tool_rejections and leaves tool_calls untouched.

  $ cat > rejected-metrics.jsonl <<'JSONL'
  > {"expect":{"body_contains":["rejected metrics prompt","\"name\":\"read_file\""]},"response":{"id":"resp-rejected-1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":4,"output_tokens":2},"output":[{"type":"function_call","id":"item-rejected","call_id":"call-rejected","name":"read_file","arguments":"{\"path\":\"\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-rejected","invalid input"]},"response":{"id":"resp-rejected-2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":6,"input_tokens_details":{"cached_tokens":1},"output_tokens":3},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"rejected metrics final"}]}]}}
  > JSONL

  $ start_fake_openai rejected-metrics.jsonl rejected-capture rejected-port
  $ spice run --cwd "$PWD" --json --permission bypass --id rejected-metrics "rejected metrics prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$TIME/g' | grep '"type":"turn.finished"'
  spice: session saved; resume with: spice resume 'rejected-metrics'
  {"schema_version":1,"type":"turn.finished","session_id":"rejected-metrics","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"rejected metrics final","metrics":{"usage":{"input":9,"output":5,"reasoning":0,"cache_read":1,"cache_write":0},"responses":2,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":1,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  $ wait_fake_server

A failed execution still ends the JSONL stream with one terminal event: the
error is classified, and the spend the session durably recorded stays
accounted. Port 9 refuses connections, so the provider call fails after
retries without any usage.

  $ SPICE_OPENAI_BASE_URL="http://127.0.0.1:9/v1" spice run --cwd "$PWD" --json --id failed-metrics "failed metrics prompt" >failed-metrics.out 2>failed-metrics.err; echo exit:$?
  exit:1
  $ sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$TIME/g; s/"message":"([^"\\]|\\.)*"/"message":"$MESSAGE"/' failed-metrics.out | grep '"type":"session.failed"'
  {"schema_version":1,"type":"session.failed","session_id":"failed-metrics","revision":"sha256:$HASH","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":0,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"error":{"kind":"provider_transport","message":"$MESSAGE"},"duration_ms":$TIME}
  $ grep -c '"type":"session.failed"' failed-metrics.out
  1
