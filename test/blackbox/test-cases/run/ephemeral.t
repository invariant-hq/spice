Ephemeral runs persist nothing: the session lives under a throwaway store
root removed when the run ends, no resume hint is printed, and the cwd's
session store stays empty.

  $ cat > ephemeral.jsonl <<'JSONL'
  > {"expect":{"body_contains":["ephemeral prompt"]},"response":{"id":"resp-ephemeral","status":"completed","model":"gpt-5.5","usage":{"input_tokens":3,"output_tokens":2},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ephemeral final"}]}]}}
  > JSONL

  $ start_fake_openai ephemeral.jsonl ephemeral-capture ephemeral-port
  $ spice run --cwd "$PWD" --ephemeral "ephemeral prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  ephemeral final
  $ wait_fake_server
  $ test -e .spice/sessions || echo no-store
  no-store

Ephemeral cannot resume an existing session.

  $ spice run resume some-session --cwd "$PWD" --ephemeral "more"
  Usage: spice run resume [--help] [OPTION]… [SESSION_OR_PROMPT] [PROMPT]
  spice: unknown option '--ephemeral'
  [124]
