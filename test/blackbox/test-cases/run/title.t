Untitled sessions get a one-shot generated title from the resolved small model
after the run reaches a durable outcome. The harness disables titling globally
(SPICE_AUTO_TITLE=0); these tests re-enable it and pin the small model.

  $ export SPICE_AUTO_TITLE=1
  $ export SPICE_SMALL_MODEL=openai/gpt-5.5

A finished first run titles the untitled session with the normalized model
reply; the title request is tool-free and derived from the first user prompt.

  $ cat > titled.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":["fix the auth tests"]},"response":{"id":"resp-main","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"main final answer"}]}]}}
  > {"expect":{"body_contains":["Generate a concise 3-5 word title","fix the auth tests"]},"response":{"id":"resp-title","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fix Auth Tests"}]}]}}
  > JSONL
  $ start_fake_openai titled.jsonl capture-titled port-titled
  $ spice run --cwd "$PWD" --id titled "fix the auth tests"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  main final answer
  spice: session saved; resume with: spice resume 'titled'
  $ wait_fake_server
  $ spice session show titled | grep '^title'
  title: Fix Auth Tests

The generated title is a durable metadata update, absent from the replayed
events.

  $ spice session export titled | grep -o '"title":"Fix Auth Tests"'
  "title":"Fix Auth Tests"
  $ spice session export titled | grep -c '"type":"turn_started"'
  1

An explicit --title wins: no title request is sent, which the fake server
proves by accepting exactly one request.

  $ cat > explicit.jsonl <<'JSONL'
  > {"expect":{"body_contains":["explicit prompt"]},"response":{"id":"resp-explicit","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"explicit final"}]}]}}
  > JSONL
  $ start_fake_openai explicit.jsonl capture-explicit port-explicit
  $ spice run --cwd "$PWD" --id explicit --title Chosen "explicit prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  explicit final
  spice: session saved; resume with: spice resume 'explicit'
  $ wait_fake_server
  $ spice session show explicit | grep '^title'
  title: Chosen

An existing title — user-set or generated — is never regenerated on later
runs.

  $ cat > already-titled.jsonl <<'JSONL'
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"resp-second","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second final"}]}]}}
  > JSONL
  $ start_fake_openai already-titled.jsonl capture-already port-already
  $ spice run resume --cwd "$PWD" titled "second prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  second final
  spice: session saved; resume with: spice resume 'titled'
  $ wait_fake_server
  $ spice session show titled | grep '^title'
  title: Fix Auth Tests

A blocked first run still gets a title: a blocked session is exactly the one a
user must find again in the list. The GPT family ships apply_patch rather than
write_file, so pin the string-replace editor family to keep write_file in the
catalog for this blocked write.

  $ spice config set tools.editor string-replace

  $ cat > blocked-title.jsonl <<'JSONL'
  > {"expect":{"body_contains":["write the file"]},"response":{"id":"resp-blocked","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-write","call_id":"call-write","name":"write_file","arguments":"{\"path\":\"out.txt\",\"contents\":\"x\"}"}]}}
  > {"expect":{"body_contains":["Generate a concise 3-5 word title","write the file"]},"response":{"id":"resp-blocked-title","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Write Output File"}]}]}}
  > JSONL
  $ start_fake_openai blocked-title.jsonl capture-blocked port-blocked
  $ spice run --cwd "$PWD" --id blocked-titled "write the file" 2>/dev/null; echo "exit=$?"
  exit=3
  $ wait_fake_server
  $ spice session show blocked-titled | grep -E '^(title|phase)'
  title: Write Output File
  phase: waiting

A failing or empty title reply leaves the session untitled without changing
the run's outcome; rows fall back to the preview.

  $ cat > empty-title.jsonl <<'JSONL'
  > {"expect":{"body_contains":["untitled prompt"]},"response":{"id":"resp-untitled","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"untitled final"}]}]}}
  > {"expect":{"body_contains":["Generate a concise 3-5 word title"]},"response":{"id":"resp-empty-title","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"   "}]}]}}
  > JSONL
  $ start_fake_openai empty-title.jsonl capture-empty port-empty
  $ spice run --cwd "$PWD" --id untitled-run "untitled prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  untitled final
  spice: session saved; resume with: spice resume 'untitled-run'
  $ wait_fake_server
  $ spice session show untitled-run | grep -E '^(title|preview)'
  title: -
  preview: untitled prompt
  $ spice session list | grep '^untitled-run'
  untitled-run    idle     just now  untitled prompt

A long model reply is normalized to one length-capped line.

  $ cat > long-title.jsonl <<'JSONL'
  > {"expect":{"body_contains":["long title prompt"]},"response":{"id":"resp-long","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"long final"}]}]}}
  > {"expect":{"body_contains":["Generate a concise 3-5 word title"]},"response":{"id":"resp-long-title","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"A Very\nLong Multi Line Title That Keeps Going Far Beyond The Sixty Byte Cap For Titles"}]}]}}
  > JSONL
  $ start_fake_openai long-title.jsonl capture-long port-long
  $ spice run --cwd "$PWD" --id long-titled "long title prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  long final
  spice: session saved; resume with: spice resume 'long-titled'
  $ wait_fake_server
  $ spice session show long-titled | grep '^title'
  title: A Very Long Multi Line Title That Keeps Going Far Beyond The

A multi-byte character straddling the sixty-byte cap is never split: the cut
backs up to the previous UTF-8 boundary.

  $ xs=$(printf 'x%.0s' $(seq 1 59))
  $ cat > boundary-title.jsonl <<JSONL
  > {"expect":{"body_contains":["boundary prompt"]},"response":{"id":"resp-boundary","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"boundary final"}]}]}}
  > {"expect":{"body_contains":["Generate a concise 3-5 word title"]},"response":{"id":"resp-boundary-title","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"${xs}\u00e9tail"}]}]}}
  > JSONL
  $ start_fake_openai boundary-title.jsonl capture-boundary port-boundary
  $ spice run --cwd "$PWD" --id boundary-titled "boundary prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  boundary final
  spice: session saved; resume with: spice resume 'boundary-titled'
  $ wait_fake_server
  $ spice session show boundary-titled | grep '^title' | wc -c | tr -d ' '
  67

Provider credentials never appear in session-management output.

  $ spice session list --json --all 2>/dev/null | grep -c test-key
  0
  [1]
  $ spice session export titled | grep -c test-key
  0
  [1]
