Headless execution modes are durable turn contracts. They affect the model
request, persist on the turn, and cannot be changed while the turn is active.

Plan mode records the workflow mode and advertises read-only discovery tools,
the plan proposal tool, questions, and subagents. It does not advertise
workspace mutation tools or todo writes.

  $ cat > plan-mode.jsonl <<'JSONL'
  > {"expect":{"body_contains":["plan prompt","\"name\":\"read_file\"","\"name\":\"search_text\"","\"name\":\"glob\"","\"name\":\"ask_user\"","\"name\":\"propose_plan\"","\"name\":\"spawn_subagent\"","plan mode"],"body_not_contains":["\"name\":\"write_file\"","\"name\":\"edit_file\"","\"name\":\"apply_patch\"","\"name\":\"shell\"","\"name\":\"todo_write\""]},"response":{"id":"resp-plan-mode","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"plan final"}]}]}}
  > JSONL

  $ start_fake_openai plan-mode.jsonl capture-plan-mode port-plan-mode
  $ spice run --cwd "$PWD" --json --mode plan --permission-mode bypass --id plan-mode "plan prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$MS/g'
  spice: session saved; resume with: spice resume 'plan-mode'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"plan-mode","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"plan-mode","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"plan","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"plan-mode","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"plan final","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$MS}
  $ wait_fake_server

  $ spice session export plan-mode | grep -o '"mode":"plan"'
  "mode":"plan"

Review mode records the workflow mode and advertises read-only discovery tools,
questions, and subagents. It does not advertise plan proposals, todo writes, or
workspace mutation tools.

  $ cat > review-mode.jsonl <<'JSONL'
  > {"expect":{"body_contains":["review prompt","\"name\":\"read_file\"","\"name\":\"search_text\"","\"name\":\"glob\"","\"name\":\"ask_user\"","\"name\":\"spawn_subagent\"","review mode"],"body_not_contains":["\"name\":\"write_file\"","\"name\":\"edit_file\"","\"name\":\"apply_patch\"","\"name\":\"shell\"","\"name\":\"todo_write\"","\"name\":\"propose_plan\""]},"response":{"id":"resp-review-mode","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"review final"}]}]}}
  > JSONL

  $ start_fake_openai review-mode.jsonl capture-review-mode port-review-mode
  $ spice run --cwd "$PWD" --json --mode review --permission-mode bypass --id review-mode "review prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$MS/g'
  spice: session saved; resume with: spice resume 'review-mode'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"review-mode","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"review-mode","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"review","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"review-mode","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"review final","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$MS}
  $ wait_fake_server

  $ spice session export review-mode | grep -o '"mode":"review"'
  "mode":"review"

Build mode is the default and advertises todo writes in addition to normal
workspace tools and host-boundary tools.

  $ cat > build-mode.jsonl <<'JSONL'
  > {"expect":{"body_contains":["build prompt","\"name\":\"apply_patch\"","\"name\":\"shell\"","\"name\":\"ask_user\"","\"name\":\"todo_write\"","\"name\":\"spawn_subagent\""],"body_not_contains":["\"name\":\"propose_plan\"","\"name\":\"write_file\"","\"name\":\"edit_file\""]},"response":{"id":"resp-build-mode","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"build final"}]}]}}
  > JSONL

  $ start_fake_openai build-mode.jsonl capture-build-mode port-build-mode
  $ spice run --cwd "$PWD" --json --permission-mode bypass --id build-mode "build prompt" | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"turn_id":"turn_[^"]+"/"turn_id":"turn_$ID"/; s/"duration_ms":[0-9]+/"duration_ms":$MS/g'
  spice: session saved; resume with: spice resume 'build-mode'
  {"schema_version":1,"type":"run.started","permission":{"mode":"bypass"},"sandbox":{"mode":"danger-full-access","origin":"config","require":"enforced","network":"enabled","backend":"none","enforcement":"not_requested"}}
  {"schema_version":1,"type":"session.started","session_id":"build-mode","revision":"sha256:$HASH"}
  {"schema_version":1,"type":"turn.started","session_id":"build-mode","revision":"sha256:$HASH","turn_id":"turn_$ID","workflow_mode":"build","projection_digest":"sha256:$HASH","context_warnings":[]}
  {"schema_version":1,"type":"turn.finished","session_id":"build-mode","revision":"sha256:$HASH","turn_id":"turn_$ID","outcome":"completed","final_text":"build final","metrics":{"usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"responses":1,"turns":1,"tool_calls":0,"tool_failures":0,"tool_rejections":0,"tool_calls_by_name":[],"permission_denials":0},"duration_ms":$MS}
  $ wait_fake_server

  $ spice session export build-mode | grep -o '"mode":"build"'
  "mode":"build"

An active turn resumes under its persisted mode. Passing a different mode is a
usage error before provider credentials are loaded.

  $ mkdir -p .spice/sessions/active-plan
  $ cat > .spice/sessions/active-plan/session.json <<'JSON'
  > {"version":1,"id":"active-plan","metadata":{"cwd":"/workspace","title":"Active plan","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","mode":"plan","input":{"type":"user","content":[{"type":"text","text":"Plan this"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}}]}
  > JSON

  $ spice run resume active-plan --mode build
  spice: active turn was started in plan mode; cannot resume it with --mode build
  [2]

  $ spice session show --json active-plan | sed -E 's/"revision":"sha256:[0-9a-f]+(:[0-9]+)?"/"revision":"sha256:$HASH"/; s/"projection_digest":"sha256:[0-9a-f]+(:[0-9]+)?"/"projection_digest":"sha256:$HASH"/; s/"created_at":[0-9]+/"created_at":$TIME/g; s/"updated_at":[0-9]+/"updated_at":$TIME/g'
  {"schema_version":1,"type":"session","session":{"id":"active-plan","title":"Active plan","preview":"Plan this","lifecycle":"active","phase":"active","forked_from":null,"event_count":1,"active_turn":"turn-1","cwd":"/workspace","created_at":$TIME,"updated_at":$TIME,"revision":"sha256:$HASH","active_model":"openai/responses:gpt-5.5","last_outcome":null,"waiting":null,"workflow_mode":"plan"},"latest_compaction":null,"context":{"projected_input_tokens_estimate":3,"basis":"estimate","context_window":1050000,"auto_compaction_limit":1030000}}
