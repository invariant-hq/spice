Live execution projects workspace context into provider input and reports the
projection identity on JSONL events.

The testcase pins its own workspace root so discovery does not walk up into
the repository that runs the tests.

  $ mkdir .git
  $ cat > AGENTS.md <<'EOF'
  > Root instruction.
  > EOF

The fake provider asserts that the request body contains the exact projected
instruction fragment as contiguous JSON-encoded message content: a mismatch
fails the run.

  $ cat > ctx.jsonl <<JSONL
  > {"expect":{"body_contains":["# AGENTS.md instructions for $PWD\\\\n\\\\n<INSTRUCTIONS>\\\\nInstructions from: ./AGENTS.md\\\\nRoot instruction.\\\\n</INSTRUCTIONS>"]},"response":{"id":"resp-ctx","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ctx final answer"}]}]}}
  > JSONL

  $ start_fake_openai ctx.jsonl capture-ctx port-ctx
  $ spice run --cwd "$PWD" --json --id ctx-live "ctx prompt" > events.jsonl
  spice: session saved; resume with: spice resume 'ctx-live'
  $ wait_fake_server
  $ grep -o '"type":"[a-z._]*"' events.jsonl
  "type":"run.started"
  "type":"session.started"
  "type":"turn.started"
  "type":"turn.finished"

turn.started carries the projection identity and warning summary.

  $ grep '"type":"turn.started"' events.jsonl | grep -o '"projection_digest":"sha256:[0-9a-f]*:[0-9]*"' | sed -E 's/[0-9a-f]{64}/HASH/; s/HASH:[0-9]+/HASH:LEN/'
  "projection_digest":"sha256:HASH:LEN"

  $ grep '"type":"turn.started"' events.jsonl | grep -o '"context_warnings":\[\]'
  "context_warnings":[]

context prompt and the executed turn agree on the projection identity for the
same working directory and flags.

  $ event_digest=$(grep '"type":"turn.started"' events.jsonl | sed -E 's/.*"projection_digest":"([^"]+)".*/\1/')
  $ prompt_digest=$(spice debug prompt --json --cwd "$PWD" | sed -E 's/.*"rendered_digest":"([^"]+)".*/\1/')
  $ test -n "$event_digest" && test "$event_digest" = "$prompt_digest" && echo agree
  agree

Durable session transcript export does not contain instruction text, while the
turn itself is durably recorded.

  $ spice session export ctx-live | grep -q 'Root instruction' || echo absent
  absent

  $ spice session export ctx-live | grep -o '"type":"turn_finished"'
  "type":"turn_finished"

Disabled project instructions do not appear in provider input.

  $ cat > ctx-off.jsonl <<JSONL
  > {"expect":{"body_contains":["ctx off prompt"]},"response":{"id":"resp-ctx-off","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ctx off final"}]}]}}
  > JSONL

  $ start_fake_openai ctx-off.jsonl capture-ctx-off port-ctx-off
  $ spice run --cwd "$PWD" --no-project-instructions --id ctx-off "ctx off prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  ctx off final
  spice: session saved; resume with: spice resume 'ctx-off'
  $ wait_fake_server
  $ grep -rq 'Root instruction' capture-ctx-off || echo absent
  absent

A new turn on an existing session refreshes the context projection from disk:
the provider sees the changed instruction text and the projection identity
changes.

  $ printf 'Changed instruction.\n' > AGENTS.md
  $ cat > ctx-second.jsonl <<JSONL
  > {"expect":{"body_contains":["Changed instruction."]},"response":{"id":"resp-ctx-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ctx second answer"}]}]}}
  > JSONL

  $ start_fake_openai ctx-second.jsonl capture-ctx-second port-ctx-second
  $ spice run resume ctx-live --cwd "$PWD" --json "ctx second prompt" > events-second.jsonl
  spice: session saved; resume with: spice resume 'ctx-live'
  $ wait_fake_server
  $ second_digest=$(grep '"type":"turn.started"' events-second.jsonl | sed -E 's/.*"projection_digest":"([^"]+)".*/\1/')
  $ test -n "$second_digest" && test "$second_digest" != "$event_digest" && echo refreshed
  refreshed
