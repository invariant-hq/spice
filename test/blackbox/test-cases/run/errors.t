Headless run validates usage and runtime assembly before mutating sessions.

Starting requires a prompt.

  $ spice run
  spice: run requires PROMPT or -
  [2]

The bare prompt spelling is sugar for the explicit start verb.

  $ spice run start
  spice: run requires PROMPT or -
  [2]

Unquoted multi-word prompts are rejected with quoting guidance.

  $ spice run fix tests
  spice: run accepts a single PROMPT; quote prompts with spaces
  [2]

Prompts may be read from stdin, but an empty stdin prompt is rejected.

  $ printf '' | spice run -
  spice: stdin prompt must not be empty
  [2]

Step limits are user input and are validated before provider credentials are
loaded.

  $ SPICE_MODEL=openai/gpt-5.5 spice run --max-steps 0 hello
  spice: --max-steps must be positive, got 0
  [2]

The permission-mode alias is accepted before runtime assembly.

  $ SPICE_MODEL=openai/gpt-5.5 spice run --permission-mode plan --max-steps 0 hello
  spice: --max-steps must be positive, got 0
  [2]

Misspelled workflow modes get a spelling hint from the declared mode
spellings, before provider credentials are loaded.

  $ spice run --mode biuld hello >err 2>&1; echo "status:$?"; sed -n 1p err; grep -c "unknown workflow mode: biuld" err; grep -c "did you mean" err
  status:124
  Usage: spice run [--help] [COMMAND] …
  1
  1

Misspelled model references get spelling hints from the provider catalog,
before provider credentials are loaded.

  $ SPICE_MODEL=openai/gpt-55 spice run hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model names unknown model "gpt-55" for provider "openai"
  Hint: did you mean gpt-5.5, gpt-5.4 or gpt-5.2?
  Hint: run `spice config unset model` to clear it
  [1]

  $ spice run --model openai/gpt-55 hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: unknown model "gpt-55" for provider "openai"
  Hint: did you mean gpt-5.5, gpt-5.4 or gpt-5.2?
  [2]

  $ spice run --model nope/gpt-5.5 hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: unknown provider "nope"
  [2]

Bare model ids on --model recover in one round trip.

  $ spice run --model gpt-5.5 hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: invalid model "gpt-5.5": model selector must be in the form provider/model
  Hint: did you mean openai/gpt-5.5?
  [2]

Coding runs require tool calling. Capability gates fail before session
creation.

  $ spice run --model openai/gpt-image-1.5 --id gated hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model "openai/gpt-image-1.5" does not support tools
  Hint: try openai/gpt-5.5
  Hint: run `spice models show openai/gpt-image-1.5` to inspect the model
  [2]
  $ test -e $SPICE_TEST_DATA_HOME/sessions/gated/session.json || echo not-created
  not-created

Unavailable models are rejected for runs with their declared reason.

  $ spice run --model openai/gpt-5-chat-latest hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: unavailable model "openai/gpt-5-chat-latest": OpenAI Responses does not support this chat alias
  Hint: run `spice models --all` to inspect model status
  [2]

The same gate failure caused by configured state is a runtime error, not a
usage error.

  $ SPICE_MODEL=openai/gpt-image-1.5 spice run hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model "openai/gpt-image-1.5" does not support tools
  Hint: try openai/gpt-5.5
  Hint: run `spice models show openai/gpt-image-1.5` to inspect the model
  [1]

Explicitly requested reasoning efforts must be supported by the model. The
request always comes from the --reasoning flag, so the failure is a usage
error even when the model itself came from configuration.

  $ spice run --model anthropic/claude-haiku-4-5 --reasoning low hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model "anthropic/claude-haiku-4-5" does not support reasoning effort low
  Hint: run `spice models show anthropic/claude-haiku-4-5` to inspect the model
  [2]

  $ SPICE_MODEL=anthropic/claude-haiku-4-5 spice run --reasoning low hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model "anthropic/claude-haiku-4-5" does not support reasoning effort low
  Hint: run `spice models show anthropic/claude-haiku-4-5` to inspect the model
  [2]

A supported effort on a reasoning-effort model passes the gate; the run then
proceeds to credential resolution as usual.

  $ spice run --model anthropic/claude-sonnet-4-6 --reasoning high hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: anthropic
  Hint: run `spice auth login anthropic` to add a credential
  [1]

Unknown effort spellings are command-line errors that list the vocabulary.

  $ spice run --reasoning hyper hello 2>&1 | grep -c "expected one of"
  1
  [124]

Stored credential kinds the provider adapter cannot use are reported with the
credential kind.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ printf '{"version":1,"credentials":{"google":{"default":{"kind":"bearer","token":"secret-token"}}}}' > "$XDG_CONFIG_HOME/spice/auth.json"
  $ SPICE_MODEL=google/gemini-3-flash-preview spice run hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: unsupported credential kind bearer for provider google
  [1]
  $ rm "$XDG_CONFIG_HOME/spice/auth.json"

A prompt that collides with a verb name is passed after the positional
separator.

  $ SPICE_MODEL=openai/gpt-5.5 spice run -- resume
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]

Without credentials, run fails before creating the requested session document.

  $ SPICE_MODEL=openai/gpt-5.5 spice run --id demo hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ test -e $SPICE_TEST_DATA_HOME/sessions/demo/session.json || echo not-created
  not-created

Missing sessions fail at the session boundary, before model credentials matter.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume missing
  spice: session not found: missing
  [1]

Execution requires an active session document. Lifecycle errors carry the
session id and surface before any model request is sent: the default model is
used and the provider base URL below points at a closed port, so a model call
would fail differently.

  $ spice session create --id archived-run
  archived-run
  $ spice session archive archived-run
  archived-run
  $ OPENAI_API_KEY=test-key SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume archived-run --cwd "$PWD" hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session is archived: archived-run
  Hint: restore it first: spice session restore 'archived-run'
  [1]

  $ spice session create --id deleted-run
  deleted-run
  $ spice session delete --yes deleted-run
  deleted-run
  $ OPENAI_API_KEY=test-key SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume deleted-run --cwd "$PWD" hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session is deleted: deleted-run
  [1]

Inactive resume without a prompt is a usage error and does not require model
credentials.

  $ spice session create --id inactive
  inactive
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume inactive
  spice: run resume requires PROMPT when no turn is active
  [2]

Start-only options do not exist on the resume verb; they fail at parsing.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume inactive --id new hello 2>&1 | grep -c unknown
  1
  [124]
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume inactive --title New hello 2>&1 | grep -c unknown
  1
  [124]

Reply requires exactly one decision, and its option pairings are validated
before any runtime assembly.

  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive
  spice: reply requires a decision: --allow, --allow-session, --deny, --question with --answer, --approve-plan, --reject-plan, or --tool-interrupted; to advance a blocked session without one, use `spice run resume SESSION`
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --message no
  spice: --message requires --deny or --reject-plan
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --question call-1
  spice: --question requires --answer
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --answer yes
  spice: --answer requires --question
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --approve-plan --reject-plan
  spice: choose only one of --approve-plan or --reject-plan
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --allow permission-1 --deny permission-1
  spice: choose only one of --allow, --allow-session, or --deny
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --approve-plan --allow permission-1
  spice: plan decision cannot be combined with another continuation
  [2]

Reply takes exactly one SESSION positional.

  $ spice run reply one two --allow permission-1 2>&1 | grep -c "too many arguments"
  1
  [124]

Permission continuations are atomic: resolving a permission immediately
advances the run, so the runtime is assembled first and nothing is recorded
when provider credentials are missing. The decision is simply retried once
credentials exist.

  $ make_permission_session () {
  >   id="$1"
  >   mkdir -p "$SPICE_TEST_DATA_HOME/sessions/$id"
  >   sed "s/\"id\":\"perm\"/\"id\":\"$id\"/" > "$SPICE_TEST_DATA_HOME/sessions/$id/session.json" <<JSON
  > {"version":1,"id":"perm","metadata":{"cwd":"$PWD","title":"Perm","status":"active","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Use the tool"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"declarations":[],"host_tools":[],"max_steps":100}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":[],"assistant":{"parts":[{"type":"tool_call","tool_call":{"id":"call-1","name":"review_tool","input":{}}}]}}},{"type":"permission_requested","request":{"id":"permission-1","turn":"turn-1","tool_call":{"id":"call-1","name":"review_tool","input":{}},"request":{"version":2,"items":[{"access":{"type":"custom","name":"review_tool"}}]},"asked":[{"type":"custom","name":"review_tool"}]}}]}
  > JSON
  > }

  $ make_permission_session allow-once
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply allow-once --allow permission-1
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ spice session export allow-once | grep -o '"type":"permission_resolved"' || echo no-resolution
  no-resolution

  $ make_permission_session allow-session
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply allow-session --allow-session permission-1
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ spice session export allow-session | grep -o '"type":"permission_resolved"' || echo no-resolution
  no-resolution

  $ make_permission_session deny
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply deny --deny permission-1
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ spice session export deny | grep -o '"type":"permission_resolved"' || echo no-resolution
  no-resolution

  $ make_permission_session deny-message
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply deny-message --deny permission-1 --message "not now"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ spice session export deny-message | grep -o '"text":"not now"' || echo no-resolution
  no-resolution

Once the runtime is assembled, a reply naming no pending permission fails
without recording anything or calling the provider.

  $ make_permission_session unknown-permission
  $ OPENAI_API_KEY=test-key SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run reply unknown-permission --cwd "$PWD" --allow permission-9
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: permission is not pending: permission-9
  [1]
  $ spice session export unknown-permission | grep -o '"type":"permission_resolved"' || echo no-resolution
  no-resolution

Decisions live on the reply verb; recovery flags fail at parsing on start.

  $ SPICE_MODEL=openai/gpt-5.5 spice run --tool-interrupted execution-1 2>&1 | grep -c unknown
  1
  [124]
  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --reason "already done"
  spice: --reason requires --tool-interrupted
  [2]

Tool recovery is atomic like permission continuations: the runtime is
assembled first, so nothing is recorded when provider credentials are missing,
and an assembled recovery naming no pending tool claim fails with a structured
error without recording anything or calling the provider.

  $ SPICE_MODEL=openai/gpt-5.5 spice run reply inactive --tool-interrupted execution-1
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ OPENAI_API_KEY=test-key SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run reply inactive --cwd "$PWD" --tool-interrupted execution-1
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: tool claim is not pending: execution-1
  Hint: run `spice session show` to find the pending tool claim id
  [1]
  $ spice session export inactive | grep -o '"type":"tool_claim_finished"' || echo no-recovery
  no-recovery

Inactive resume with a prompt still assembles the runtime before mutating the
session.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume inactive hello
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: missing credential for provider: openai
  Hint: run `spice auth login openai` to add a credential
  [1]
  $ spice session export inactive | sed -E 's/"(created_at|updated_at)":[0-9]+/"\1":$TIME/g'
  {"version":1,"id":"inactive","metadata":{"status":"active","cwd":"$TESTCASE_ROOT","created_at":$TIME,"updated_at":$TIME},"events":[]}
