Live session execution is tested through the public CLI, the real host runtime,
and a local OpenAI Responses-compatible fixture server.

The simplest live turn creates a session, calls the configured model once,
prints the final assistant text, and persists an idle session document.

  $ cat > simple.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":["\"model\":\"gpt-5.5\"","plain prompt"]},"response":{"id":"resp-simple","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"plain final answer"}]}]}}
  > JSONL

  $ start_fake_openai simple.jsonl capture-simple port-simple
  $ spice run --cwd "$PWD" --id plain-live "plain prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  plain final answer
  spice: session saved; resume with: spice resume 'plain-live'
  $ wait_fake_server

  $ spice session show --json plain-live | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"plain-live","title":null,"preview":"plain prompt","lifecycle":"active","phase":"idle","forked_from":null,"event_count":3,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":8,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export plain-live | grep -o '"type":"turn_finished"'
  "type":"turn_finished"

A read-only tool loop durably claims and finishes the tool before the model sees
the tool result in the follow-up request.

  $ printf 'alpha beta' > input.txt
  $ cat > read-tool.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.5\"","read input.txt","\"name\":\"read_file\""]},"response":{"id":"resp-read-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-read-1","call_id":"call-read-1","name":"read_file","arguments":"{\"path\":\"input.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-read-1","alpha beta"]},"response":{"id":"resp-read-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"read final answer"}]}]}}
  > JSONL

  $ start_fake_openai read-tool.jsonl capture-read port-read
  $ spice run --cwd "$PWD" --permission-mode bypass --id read-live "read input.txt"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool read_file running
  ✓ tool read_file input.txt completed: 1 lines
  read final answer
  spice: session saved; resume with: spice resume 'read-live'
  $ wait_fake_server

  $ spice session show --json read-live | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"read-live","title":null,"preview":"read input.txt","lifecycle":"active","phase":"idle","forked_from":null,"event_count":6,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":110,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export read-live | grep -o '"type":"tool_claim_started"'
  "type":"tool_claim_started"
  $ spice session export read-live | grep -o '"type":"tool_claim_finished"'
  "type":"tool_claim_finished"
  $ grep -o '"type":"function_call_output"' capture-read/request-2.json
  "type":"function_call_output"
  $ grep -o '"call_id":"call-read-1"' capture-read/request-2.json
  "call_id":"call-read-1"
  "call_id":"call-read-1"

Resuming an idle saved session with a prompt starts a new turn on the same
session. The next provider request carries the new user prompt and preserves
continuity through the provider response chain.

  $ cat > resume-first.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"resp-resume-1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > JSONL
  $ start_fake_openai resume-first.jsonl capture-resume-first port-resume-first
  $ spice run --cwd "$PWD" --id resume-live "first prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  first answer
  spice: session saved; resume with: spice resume 'resume-live'
  $ wait_fake_server

  $ cat > resume-second.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt","first answer","second prompt"]},"response":{"id":"resp-resume-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > JSONL
  $ start_fake_openai resume-second.jsonl capture-resume-second port-resume-second
  $ spice run resume resume-live --cwd "$PWD" "second prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  second answer
  spice: session saved; resume with: spice resume 'resume-live'
  $ wait_fake_server

  $ spice session show --json resume-live | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"resume-live","title":null,"preview":"first prompt","lifecycle":"active","phase":"idle","forked_from":null,"event_count":6,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":14,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export resume-live | grep -o '"text":"second prompt"'
  "text":"second prompt"
  $ grep -o '"previous_response_id"' capture-resume-second/request-1.json || echo no-continuation-chaining
  no-continuation-chaining
  $ grep -o '"prompt_cache_key":"resume-live"' capture-resume-second/request-1.json
  "prompt_cache_key":"resume-live"

Successful JSON output is JSONL: session creation, durable turn start, and the
terminal turn result are emitted as separate product events.

  $ cat > json-success.jsonl <<'JSONL'
  > {"expect":{"body_contains":["json prompt"]},"response":{"id":"resp-json","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"json final answer"}]}]}}
  > JSONL

  $ start_fake_openai json-success.jsonl capture-json port-json
  $ spice run --cwd "$PWD" --json --id json-live "json prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/g; s/"duration_ms":[0-9]+/"duration_ms":$MS/g'
  spice: session saved; resume with: spice resume 'json-live'
  {"schema_version":1,"type":"run.started","permission":{"mode":"default"},"sandbox":{"mode":"danger-full-access","read":"all","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"json-live","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"json-live","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"json-live","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"json final answer","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$MS}
  $ wait_fake_server
