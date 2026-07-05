Live session recovery is tested through persisted session documents and the
public CLI. The crash boundary is represented by a minimal session whose tool
execution has been durably started but not finished. That is the state Spice
must never recover from by rerunning the tool automatically.

  $ make_unfinished_tool_session () {
  >   mkdir -p .spice/sessions/crashed-tool
  >   cat > .spice/sessions/crashed-tool/session.json <<'JSON'
  > {"version":1,"id":"crashed-tool","metadata":{"cwd":"/workspace","title":"Crashed tool","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Write crash.txt"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-write-crash","name":"write_file","input":{"path":"crash.txt","contents":"crashed contents"}}}]}}},{"type":"tool_claim_started","execution":{"id":"tool_exec-crashed","turn":"turn-1","call":{"id":"call-write-crash","name":"write_file","input":{"path":"crash.txt","contents":"crashed contents"}}}}]}
  > JSON
  > }

  $ make_unfinished_tool_session

Status reports the unfinished execution as a live blocked session, with enough
machine-readable data for a product surface to render the recovery action.

  $ spice session show --json crashed-tool | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"crashed-tool","title":"Crashed tool","preview":"Write crash.txt","lifecycle":"active","phase":"waiting","forked_from":null,"event_count":3,"active_turn":"turn-1","cwd":"/workspace","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":"openai/responses:gpt-5.5","last_outcome":null,"waiting":{"kind":"tool_claim","claim_id":"tool_exec-crashed","turn":"turn-1","tool_call_id":"call-write-crash","tool":"write_file"}},"latest_compaction":null,"context":{"projected_input_tokens_estimate":68,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}

Resuming the session without an explicit recovery does not rerun the started
tool. No fake provider is listening here: if Spice tried to continue to a model
request or rerun the write, this would either fail differently or create the
file.

  $ OPENAI_API_KEY=test-key SPICE_MODEL=openai/gpt-5.5 SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume crashed-tool --cwd "$PWD" --json >blocked-recovery.out 2>&1; echo exit:$?
  exit:3
  $ sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/' blocked-recovery.out | grep -o '{"schema_version":1,"type":"session.waiting".*'
  {"schema_version":1,"type":"session.waiting","session_id":"crashed-tool","revision":"sha256:$HASH","waiting":{"kind":"tool_claim","claim_id":"tool_exec-crashed","turn":"turn-1","tool_call_id":"call-write-crash","tool":"write_file"},"metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":0,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  $ grep -o 'spice: session blocked' blocked-recovery.out
  spice: session blocked
  $ test -e crash.txt || echo not-rerun
  not-rerun
  $ spice session export crashed-tool | grep -o '"type":"tool_claim_finished"' || echo still-unfinished
  still-unfinished

An explicit interrupted-tool continuation records a model-visible interrupted
tool result, resumes at the model boundary, and finishes the same turn.

  $ cat > recovery-finish.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-write-crash","interrupted after restart"]},"response":{"id":"resp-recovered","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"recovered final"}]}]}}
  > JSONL
  $ start_fake_openai recovery-finish.jsonl recovery-capture recovery-port
  $ spice run reply crashed-tool --cwd "$PWD" --json --tool-interrupted tool_exec-crashed --reason "interrupted after restart" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/'
  spice: session saved; resume with: spice resume 'crashed-tool'
  {"schema_version":1,"type":"run.started","permission":{"mode":"default"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"turn.finished","session_id":"crashed-tool","revision":"sha256:$HASH","turn_id":"turn-1","outcome":"completed","final_text":"recovered final","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":2,"turns":1,"tool_calls":1,"tool_failures":1,"tool_rejections":0,"tool_calls_by_name":[{"name":"write_file","count":1}],"permission_denials":0},"duration_ms":$TIME}
  $ wait_fake_server

The recovery does not perform the original write, and the durable session now
contains the finished execution and final idle state.

  $ test -e crash.txt || echo original-write-not-run
  original-write-not-run
  $ spice session show --json crashed-tool | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"crashed-tool","title":"Crashed tool","preview":"Write crash.txt","lifecycle":"active","phase":"idle","forked_from":null,"event_count":6,"active_turn":null,"cwd":"/workspace","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":79,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export crashed-tool | grep -o '"type":"tool_claim_finished"'
  "type":"tool_claim_finished"
  $ spice session export crashed-tool | grep -o '"text":"interrupted after restart"'
  "text":"interrupted after restart"
  $ grep -o '"type":"function_call_output"' recovery-capture/request-1.json
  "type":"function_call_output"
  $ grep -o '"call_id":"call-write-crash"' recovery-capture/request-1.json | head -n 1
  "call_id":"call-write-crash"
  $ grep -o 'interrupted after restart' recovery-capture/request-1.json
  interrupted after restart

Blocked live runs emit JSONL events that product surfaces can consume without
scraping human continuation text. The GPT family ships apply_patch rather than
write_file, so pin the string-replace editor family to keep write_file in the
catalog for this blocked write.

  $ spice config set tools.editor string-replace

  $ cat > json-block.jsonl <<'JSONL'
  > {"expect":{"body_contains":["json blocked write","\"name\":\"write_file\""]},"response":{"id":"resp-json-block","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-json-block","call_id":"call-json-block","name":"write_file","arguments":"{\"path\":\"json-blocked.txt\",\"contents\":\"blocked\"}"}]}}
  > JSONL
  $ start_fake_openai json-block.jsonl json-block-capture json-block-port
  $ spice run --cwd "$PWD" --json --id json-blocked "json blocked write" >json-blocked.out 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server
  $ grep -o '"type":"session.started"\|"type":"turn.started"\|"type":"permission.requested"\|"type":"session.waiting"' json-blocked.out
  "type":"session.started"
  "type":"turn.started"
  "type":"permission.requested"
  "type":"session.waiting"
  $ grep -o '"kind":"permission"' json-blocked.out
  "kind":"permission"
  $ grep -o '"tool":"write_file"' json-blocked.out
  "tool":"write_file"
  "tool":"write_file"
  $ grep -o '"tool_call_id":"call-json-block"' json-blocked.out
  "tool_call_id":"call-json-block"
  "tool_call_id":"call-json-block"
  $ grep -o 'spice: session blocked' json-blocked.out
  spice: session blocked
  $ test -e json-blocked.txt || echo blocked-write-not-run
  blocked-write-not-run
