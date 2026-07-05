Automatic compaction is part of headless execution: context pressure compacts
before an unsafe model request, provider context overflow compacts once and
retries the same turn once, and the lifecycle is visible as terse human
progress or schema-versioned JSONL.

The pressure trigger is grounded in provider-reported usage: a response that
reports near-limit usage makes the next request boundary compact, with no
large fixtures. gpt-5.5's catalog window is 1,050,000 tokens and the derived
automatic limit reserves 20,000 of output headroom, so reported usage of
1,040,000 is over the 1,030,000 limit.

Pressure compaction, JSONL lifecycle. Lifecycle events carry the session id
and no revision; the durable compaction.installed event carries the saved
post-install revision.

  $ cat > pressure-json.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"r1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"r2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1040000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"expect":{"body_contains":["Summarize the conversation history above","first prompt","first answer","\"tool_choice\":\"none\""],"body_not_contains":["third prompt"]},"response":{"id":"r3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Compact summary: first turn handled."}]}]}}
  > {"expect":{"body_contains":["Compact summary: first turn handled.","second prompt","third prompt"],"body_not_contains":["first answer"]},"response":{"id":"r4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"third answer after compaction"}]}]}}
  > JSONL
  $ start_fake_openai pressure-json.jsonl pressure-json-capture pressure-json-port
  $ spice run --cwd "$PWD" --id pressure-json "first prompt" 2>/dev/null
  first answer
  $ spice run resume pressure-json --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume pressure-json --json --cwd "$PWD" "third prompt" >pressure-json.out 2>/dev/null
  $ wait_fake_server
  $ grep -o '"type":"[a-z._]*"' pressure-json.out
  "type":"run.started"
  "type":"turn.started"
  "type":"compaction.started"
  "type":"compaction.model_started"
  "type":"compaction.installed"
  "type":"turn.finished"
  $ grep -o '"reason":"context_pressure"' pressure-json.out | head -1
  "reason":"context_pressure"
  $ grep -o '"auto_limit":1030000' pressure-json.out
  "auto_limit":1030000
  $ grep -o '"basis":"usage"' pressure-json.out
  "basis":"usage"
  $ grep -o '"model":"[^"]*"' pressure-json.out
  "model":"openai/responses:gpt-5.5"
  "model":"openai/responses:gpt-5.5"
  $ grep -o '"summarized_messages":2' pressure-json.out
  "summarized_messages":2
  $ grep -o '"retained_tail_messages":3' pressure-json.out
  "retained_tail_messages":3
  $ grep -o '"summary":"Compact summary: first turn handled."' pressure-json.out
  "summary":"Compact summary: first turn handled."

No credential reaches the output stream.

  $ grep -c "test-key" pressure-json.out
  0
  [1]

The lifecycle events carry no revision; the installed event does.

  $ grep '"type":"compaction.started"' pressure-json.out | grep -c '"revision"'
  0
  [1]
  $ grep '"type":"compaction.installed"' pressure-json.out | grep -c '"revision":"sha256:'
  1

Pressure compaction, human progress. No token numbers in human lines.

  $ cat > pressure-human.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"h1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"h2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1040000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"expect":{"body_contains":["Summarize the conversation history above"]},"response":{"id":"h3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Human summary."}]}]}}
  > {"expect":{"body_contains":["Human summary.","third prompt"]},"response":{"id":"h4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"third answer after compaction"}]}]}}
  > JSONL
  $ start_fake_openai pressure-human.jsonl pressure-human-capture pressure-human-port
  $ spice run --cwd "$PWD" --id pressure-human "first prompt" 2>/dev/null
  first answer
  $ spice run resume pressure-human --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume pressure-human --cwd "$PWD" "third prompt" 2>/dev/null
  compacting: context_pressure
  compacted: summarized=2 retained=3
  third answer after compaction
  $ wait_fake_server

After the compaction the session status reports usage-informed context facts
again only once a new response records usage; the summary response carries
none, so the basis is the estimate.

  $ spice session show pressure-human | sed -E 's/^(created|updated)_at: [0-9]+/\1_at: $TIME/; s/^revision: sha256:[0-9a-f]+(:[0-9]+)?/revision: sha256:$HASH/'
  id: pressure-human
  title: -
  preview: first prompt
  lifecycle: active
  phase: idle
  events: 10
  forked_from: -
  cwd: $TESTCASE_ROOT
  created_at: $TIME
  updated_at: $TIME
  revision: sha256:$HASH
  latest_compaction: context_pressure summarized=2 retained=3
  $ spice session show --json pressure-human | grep -o '"basis":"[a-z]*"'
  "basis":"estimate"

Provider context overflow compacts once and retries the same turn once. The
human progress names the recovery.

  $ cat > overflow-human.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"o1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"o2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > {"expect":{"body_contains":["Summarize the conversation history above","first prompt"],"body_not_contains":["third prompt"]},"response":{"id":"o4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Overflow summary."}]}]}}
  > {"expect":{"body_contains":["Overflow summary.","third prompt"],"body_not_contains":["first answer"]},"response":{"id":"o5","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"third answer after recovery"}]}]}}
  > JSONL
  $ start_fake_openai overflow-human.jsonl overflow-human-capture overflow-human-port
  $ spice run --cwd "$PWD" --id overflow-human "first prompt" 2>/dev/null
  first answer
  $ spice run resume overflow-human --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume overflow-human --cwd "$PWD" "third prompt" 2>/dev/null
  compacting: context_overflow
  compacted: summarized=2 retained=3
  retrying after compaction
  third answer after recovery
  $ wait_fake_server
  $ spice session export overflow-human | grep -o '"type":"turn_started"' | wc -l | tr -d ' '
  3

A second overflow after recovery fails clearly and does not loop: exactly one
compaction is installed and the turn fails with the provider error.

  $ cat > overflow-twice.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"t1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"t2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > {"expect":{"body_contains":["Summarize the conversation history above"]},"response":{"id":"t4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Twice summary."}]}]}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > JSONL
  $ start_fake_openai overflow-twice.jsonl overflow-twice-capture overflow-twice-port
  $ spice run --cwd "$PWD" --id overflow-twice "first prompt" 2>/dev/null
  first answer
  $ spice run resume overflow-twice --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume overflow-twice --json --cwd "$PWD" "third prompt" >overflow-twice.out 2>/dev/null; echo "exit:$?"
  exit:1
  $ wait_fake_server
  $ grep -o '"type":"[a-z._]*"' overflow-twice.out
  "type":"run.started"
  "type":"turn.started"
  "type":"compaction.started"
  "type":"compaction.model_started"
  "type":"compaction.installed"
  "type":"session.failed"
  $ grep -c '"type":"compaction.installed"' overflow-twice.out
  1
  $ grep -o '"kind":"provider_context_overflow"' overflow-twice.out
  "kind":"provider_context_overflow"

When the summary request itself overflows, the oldest summary input is dropped
and the summary is retried within the bounded retry policy.

  $ cat > trim-retry.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"m1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"m2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > {"expect":{"body_contains":["Summarize the conversation history above","first answer"],"body_not_contains":["first prompt"]},"response":{"id":"m5","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Trimmed summary."}]}]}}
  > {"expect":{"body_contains":["Trimmed summary.","third prompt"]},"response":{"id":"m6","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"third answer after trim"}]}]}}
  > JSONL
  $ start_fake_openai trim-retry.jsonl trim-retry-capture trim-retry-port
  $ spice run --cwd "$PWD" --id trim-retry "first prompt" 2>/dev/null
  first answer
  $ spice run resume trim-retry --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume trim-retry --json --cwd "$PWD" "third prompt" >trim-retry.out 2>/dev/null
  $ wait_fake_server
  $ grep -o '"type":"compaction.retrying"' trim-retry.out
  "type":"compaction.retrying"
  $ grep -o '"dropped_messages":1' trim-retry.out
  "dropped_messages":1
  $ grep -c '"type":"compaction.installed"' trim-retry.out
  1

A pressure-compaction summary failure fails the turn with a structured error
and installs nothing: no silent fallback to the un-compacted request.

  $ cat > pressure-fail.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"f1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"f2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1040000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"http":{"status":400,"body":{"error":{"message":"summary rejected","type":"invalid_request_error"}}}}
  > JSONL
  $ start_fake_openai pressure-fail.jsonl pressure-fail-capture pressure-fail-port
  $ spice run --cwd "$PWD" --id pressure-fail "first prompt" 2>/dev/null
  first answer
  $ spice run resume pressure-fail --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume pressure-fail --json --cwd "$PWD" "third prompt" >pressure-fail.out 2>/dev/null; echo "exit:$?"
  exit:1
  $ wait_fake_server
  $ grep -o '"type":"[a-z._]*"' pressure-fail.out
  "type":"run.started"
  "type":"turn.started"
  "type":"compaction.started"
  "type":"compaction.model_started"
  "type":"compaction.failed"
  "type":"session.failed"
  $ spice session export pressure-fail | grep -c '"type":"compaction_installed"'
  0
  [1]

An overflow that cannot be compacted — the default policy retains the two
newest turn groups, so a two-group session has no summarizable head — surfaces
the original provider error and mutates nothing.

  $ cat > overflow-empty.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"u1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > JSONL
  $ start_fake_openai overflow-empty.jsonl overflow-empty-capture overflow-empty-port
  $ spice run --cwd "$PWD" --id overflow-empty "first prompt" 2>/dev/null
  first answer
  $ spice run resume overflow-empty --json --cwd "$PWD" "second prompt" >overflow-empty.out 2>/dev/null; echo "exit:$?"
  exit:1
  $ wait_fake_server
  $ grep -c '"type":"compaction.installed"' overflow-empty.out
  0
  [1]
  $ grep -o '"kind":"provider_context_overflow"' overflow-empty.out
  "kind":"provider_context_overflow"
  $ spice session export overflow-empty | grep -o '"type":"compaction_installed"' | wc -l | tr -d ' '
  0
  [1]

Pressure with no summarizable head proceeds with the original request instead
of failing: compaction cannot help, and the estimate may be wrong in the safe
direction.

  $ cat > pressure-empty.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"p1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1040000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["first prompt","second prompt"]},"response":{"id":"p2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer uncompacted"}]}]}}
  > JSONL
  $ start_fake_openai pressure-empty.jsonl pressure-empty-capture pressure-empty-port
  $ spice run --cwd "$PWD" --id pressure-empty "first prompt" 2>/dev/null
  first answer
  $ spice run resume pressure-empty --json --cwd "$PWD" "second prompt" >pressure-empty.out 2>/dev/null
  $ wait_fake_server
  $ grep -c '"type":"compaction.installed"' pressure-empty.out
  0
  [1]
  $ grep -o '"type":"compaction.started"' pressure-empty.out
  "type":"compaction.started"
  $ grep -o '"type":"compaction.skipped"' pressure-empty.out
  "type":"compaction.skipped"
  $ grep -o '"type":"compaction.failed"' pressure-empty.out
  [1]
  $ grep -o '"type":"turn.finished"' pressure-empty.out
  "type":"turn.finished"

Disabling automatic compaction is an explicit user choice: pressure does not
compact, overflow surfaces as a clear model error, and manual compaction is
unaffected.

  $ spice config set compaction.auto false
  $ cat > disabled.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"d1","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"d2","status":"completed","model":"gpt-5.5","usage":{"input_tokens":1040000,"output_tokens":10},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > {"expect":{"body_contains":["first prompt","second prompt","third prompt"]},"response":{"id":"d3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"third answer uncompacted"}]}]}}
  > JSONL
  $ start_fake_openai disabled.jsonl disabled-capture disabled-port
  $ spice run --cwd "$PWD" --id compaction-disabled "first prompt" 2>/dev/null
  first answer
  $ spice run resume compaction-disabled --cwd "$PWD" "second prompt" 2>/dev/null
  second answer
  $ spice run resume compaction-disabled --json --cwd "$PWD" "third prompt" >disabled.out 2>/dev/null
  $ wait_fake_server
  $ grep -c '"type":"compaction' disabled.out
  0
  [1]
  $ grep -o '"type":"turn.finished"' disabled.out
  "type":"turn.finished"

Overflow with automatic compaction disabled is a clear model error, not a
recovery.

  $ cat > disabled-overflow.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"e1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"http":{"status":413,"body":{"error":{"message":"context length exceeded","code":"context_length_exceeded"}}}}
  > JSONL
  $ start_fake_openai disabled-overflow.jsonl disabled-overflow-capture disabled-overflow-port
  $ spice run --cwd "$PWD" --id disabled-overflow "first prompt" 2>/dev/null
  first answer
  $ spice run resume disabled-overflow --json --cwd "$PWD" "second prompt" >disabled-overflow.out 2>/dev/null; echo "exit:$?"
  exit:1
  $ wait_fake_server
  $ grep -c '"type":"compaction' disabled-overflow.out
  0
  [1]
  $ grep -o '"kind":"provider_context_overflow"' disabled-overflow.out
  "kind":"provider_context_overflow"

Manual compaction ignores the disable key.

  $ cat > disabled-manual.jsonl <<'JSONL'
  > {"expect":{"body_contains":["Summarize the conversation history above"]},"response":{"id":"g1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Manual summary while disabled."}]}]}}
  > JSONL
  $ start_fake_openai disabled-manual.jsonl disabled-manual-capture disabled-manual-port
  $ spice session compact --cwd "$PWD" compaction-disabled
  compacted compaction-disabled summarized=2 retained=4
  $ wait_fake_server
  $ spice config unset compaction.auto
