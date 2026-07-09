Current-model resolution explains provenance and passive credential
readiness for both roles, without provider network calls.

  $ git init -q

Without configuration, the main model is the first provider default and the
small model is the cheapest same-provider small model.

  $ spice models current
  ROLE   MODEL                SOURCE            CREDENTIALS
  model  openai/gpt-5.5       provider default  missing
  small  openai/gpt-5.4-nano  small heuristic   missing

  $ spice models current --json | tr ',' '\n' | grep fallback_reason
  "fallback_reason":"provider_default"
  "fallback_reason":"small_heuristic"

Environment credentials surface as passive readiness. Readiness is local
presence only; no provider call validates the credential.

  $ OPENAI_API_KEY=test-key spice models current
  ROLE   MODEL                SOURCE             CREDENTIALS
  model  openai/gpt-5.5       connected default  present (env OPENAI_API_KEY)
  small  openai/gpt-5.4-nano  small heuristic    present (env OPENAI_API_KEY)

  $ OPENAI_API_KEY=test-key spice models current --json | grep -o '"credentials":{[^}]*}' | sort -u
  "credentials":{"status":"present","source":"env","source_name":"OPENAI_API_KEY"}

Environment model overrides report their env origin, and the small model
follows the main model's provider.

  $ SPICE_MODEL=anthropic/claude-sonnet-4-6 spice models current
  ROLE   MODEL                        SOURCE           CREDENTIALS
  model  anthropic/claude-sonnet-4-6  env SPICE_MODEL  missing
  small  anthropic/claude-haiku-4-5   small heuristic  missing

  $ SPICE_MODEL=google/gemini-3-pro spice models current
  spice: model names unknown model "gemini-3-pro" for provider "google"
  Hint: run `spice config unset model` to clear it
  [1]

Configured models report their config-file origin.

  $ spice config set model openai/gpt-5.4
  $ spice config set small_model openai/gpt-5.4-mini
  $ spice models current
  ROLE   MODEL                SOURCE       CREDENTIALS
  model  openai/gpt-5.4       user config  missing
  small  openai/gpt-5.4-mini  user config  missing

  $ spice models current --json | tr ',' '\n' | grep -o '"origin":{"source":{"kind":"user"'
  "origin":{"source":{"kind":"user"
  "origin":{"source":{"kind":"user"

Provider base URL overrides are visible where they affect execution.

  $ SPICE_OPENAI_BASE_URL=https://proxy.example/v1 spice models current --json | grep -o '"base_url":"https://proxy.example/v1"' | wc -l | tr -d ' '
  2

Stale configured selectors are runtime errors that name the key and the
reset command. Nothing is mutated.

  $ SPICE_MODEL=openai/gpt-4 spice models current
  spice: model names unknown model "gpt-4" for provider "openai"
  Hint: did you mean gpt-5.4?
  Hint: run `spice config unset model` to clear it
  [1]
  $ spice config get model
  openai/gpt-5.4
