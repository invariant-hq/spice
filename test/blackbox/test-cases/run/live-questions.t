Live sessions can block on host-boundary user questions and resume after the
user answers through the CLI.

The fake OpenAI server scripts prove the product boundary: the first request
advertises the ask_user host tool, and the resumed request sends the answer as a
model-visible tool result before receiving final assistant text.

  $ cat > question.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.5\"","\"name\":\"ask_user\""]},"response":{"id":"resp-question","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-question","call_id":"question-1","name":"ask_user","arguments":"{\"question\":\"Which deployment target should I use?\"}"}]}}
  > JSONL
  $ start_fake_openai question.jsonl question-capture question-port

  $ spice run --cwd "$PWD" --permission-mode bypass --id needs-answer "deploy the app"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session needs-answer waiting: user question call=question-1 question='Which deployment target should I use?'
  answer: spice run reply 'needs-answer' --question 'question-1' --answer TEXT
  [3]
  $ wait_fake_server

The saved session is waiting on the durable host-tool call.

  $ spice session show needs-answer | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: needs-answer
  title: -
  preview: deploy the app
  lifecycle: active
  phase: waiting
  events: 2
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  waiting: user question call=question-1 question='Which deployment target should I use?'
  answer: spice run reply 'needs-answer' --question 'question-1' --answer TEXT
  $ spice session show --json needs-answer | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"active_turn":"turn_[^"]+"/"active_turn":"turn_$ID"/; s/"turn":"turn_[^"]+"/"turn":"turn_$ID"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"needs-answer","title":null,"preview":"deploy the app","lifecycle":"active","phase":"waiting","forked_from":null,"event_count":2,"active_turn":"turn_$ID","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":"openai/responses:gpt-5.5","last_outcome":null,"waiting":{"kind":"host_tool","turn":"turn_$ID","tool_call_id":"question-1","tool":"ask_user","question":"Which deployment target should I use?"},"workflow_mode":"build"},"latest_compaction":null,"context":{"projected_input_tokens_estimate":68,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ spice session export needs-answer | grep -o '"name":"ask_user"' | wc -l | tr -d ' '
  2

Answering the question appends a model-visible tool result and resumes the turn.

  $ cat > answer.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","question-1","User answered: staging"]},"response":{"id":"resp-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Deploying to staging."}]}]}}
  > JSONL
  $ start_fake_openai answer.jsonl answer-capture answer-port

  $ spice run reply needs-answer --cwd "$PWD" --question question-1 --answer staging
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  Deploying to staging.
  spice: session saved; resume with: spice resume 'needs-answer'
  $ wait_fake_server

The resumed session is finished, and the provider saw the question answer as a
tool result.

  $ spice session show --json needs-answer | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"needs-answer","title":null,"preview":"deploy the app","lifecycle":"active","phase":"idle","forked_from":null,"event_count":5,"active_turn":null,"cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":null,"last_outcome":"completed","waiting":null},"latest_compaction":null,"context":{"projected_input_tokens_estimate":80,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
  $ grep -o '"type":"function_call_output"' answer-capture/request-1.json
  "type":"function_call_output"
  $ grep -o '"call_id":"question-1"' answer-capture/request-1.json
  "call_id":"question-1"
  "call_id":"question-1"
  $ grep -o 'User answered: staging' answer-capture/request-1.json
  User answered: staging

JSON mode exposes the same blocked and finished lifecycle for product clients.

  $ cat > json-question.jsonl <<'JSONL'
  > {"response":{"id":"resp-json-question","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-json-question","call_id":"json-question-1","name":"ask_user","arguments":"{\"question\":\"Which region?\"}"}]}}
  > JSONL
  $ start_fake_openai json-question.jsonl json-question-capture json-question-port

  $ spice run --json --cwd "$PWD" --permission-mode bypass --id json-question "choose a region" 2>&1 | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"turn":"turn_[^"]+"/"turn":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"json-question","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"json-question","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"session.waiting","session_id":"json-question","revision":"sha256:$HASH","waiting":{"kind":"host_tool","turn":"turn_$ID","tool_call_id":"json-question-1","tool":"ask_user","question":"Which region?"},"metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":0,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  spice: session blocked
  [3]
  $ wait_fake_server

  $ cat > json-answer.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","json-question-1","User answered: eu-west"]},"response":{"id":"resp-json-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Using eu-west."}]}]}}
  > JSONL
  $ start_fake_openai json-answer.jsonl json-answer-capture json-answer-port

  $ spice run reply json-question --json --cwd "$PWD" --question json-question-1 --answer eu-west | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$TIME/'
  spice: session saved; resume with: spice resume 'json-question'
  {"schema_version":1,"type":"run.started","permission":{"mode":"default"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"turn.finished","session_id":"json-question","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"Using eu-west.","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":2,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$TIME}
  $ wait_fake_server
