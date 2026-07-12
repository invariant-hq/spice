Exec consumes configured reasoning for main conversation requests. The request
also asks for a reasoning summary ("summary":"auto") so the model returns the
human-readable thinking text the TUI renders; without it the Responses API emits
reasoning but no summary. (The fake provider emits summary deltas
unconditionally, so a render test alone cannot catch a request that fails to ask
— this body assertion is what guards the request.)

  $ spice config set model openai/gpt-5.5
  $ spice config set reasoning high

  $ cat > configured-reasoning.jsonl <<'JSONL'
  > {"expect":{"body_contains":["reasoning prompt","\"reasoning\":{\"effort\":\"high\"","\"summary\":\"auto\""]},"response":{"id":"resp-configured-reasoning","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"configured reasoning final"}]}]}}
  > JSONL
  $ start_fake_openai configured-reasoning.jsonl configured-reasoning-capture configured-reasoning-port

  $ OPENAI_API_KEY=test-key spice run --cwd "$PWD" --id configured-reasoning "reasoning prompt" >/dev/null
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session saved; resume with: spice resume 'configured-reasoning'
  $ wait_fake_server

The per-run flag shadows configured reasoning.

  $ cat > flag-reasoning.jsonl <<'JSONL'
  > {"expect":{"body_contains":["flag prompt","\"reasoning\":{\"effort\":\"low\"","\"summary\":\"auto\""],"body_not_contains":["\"reasoning\":{\"effort\":\"high\""]},"response":{"id":"resp-flag-reasoning","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"flag reasoning final"}]}]}}
  > JSONL
  $ start_fake_openai flag-reasoning.jsonl flag-reasoning-capture flag-reasoning-port

  $ OPENAI_API_KEY=test-key spice run --cwd "$PWD" --reasoning low --id flag-reasoning "flag prompt" >/dev/null
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session saved; resume with: spice resume 'flag-reasoning'
  $ wait_fake_server

Unsupported configured reasoning is host state, so it fails as a runtime error
and names the config repair command.

  $ spice config set model anthropic/claude-haiku-4-5
  $ spice config set reasoning low
  $ SPICE_MODEL=anthropic/claude-haiku-4-5 spice run hello
  permission review: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model "anthropic/claude-haiku-4-5" does not support reasoning effort low
  Hint: run `spice config unset reasoning` to clear it
  [1]
