Headless resume: `spice run resume` advances a saved session or starts a new
turn on it. The interactive counterpart is top-level `spice resume`.

Resume without a target is a usage error naming the discovery commands.

  $ spice run resume
  spice: run resume requires SESSION or --last; run `spice session list` or `spice run resume --last`
  [2]

With no sessions at all, --last says so and points at run.

  $ spice run resume --last
  spice: no sessions found; run `spice session list` or start one with `spice run`
  [1]

When the newest session lives in another directory and none live here, --last
refuses with a copy-pasteable cd command.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/elsewhere
  $ cat > $SPICE_TEST_DATA_HOME/sessions/elsewhere/session.json <<'JSON'
  > {"version":1,"id":"elsewhere","metadata":{"cwd":"/some/other/project","title":"Elsewhere","status":"active","created_at":1,"updated_at":99999999999999},"events":[]}
  > JSON
  $ spice run resume --last
  spice: no session in $TESTCASE_ROOT; most recent session is 'elsewhere' in /some/other/project; run: cd '/some/other/project' && spice run resume 'elsewhere'
  [1]

Missing sessions fail at the session boundary, before credentials matter.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume missing
  spice: session not found: missing
  [1]

Dash-prefixed ids parse after the positional separator.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume -- -dashed
  spice: session not found: -dashed
  [1]

Idle sessions need a prompt.

  $ spice session create --id idle-session --title Idle
  idle-session
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume idle-session
  spice: run resume requires PROMPT when no turn is active
  [2]

Unique id prefixes resolve to the same target; ambiguity fails loudly.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume idle-sess
  spice: run resume requires PROMPT when no turn is active
  [2]
  $ spice session create --id idle-twin --title Twin
  idle-twin
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume idle
  spice: ambiguous session id prefix "idle": matches idle-twin, idle-session
  [1]

--last selects the newest session recorded in this directory — never the
newer one recorded elsewhere — and the idle selection then asks for a prompt,
which proves the selection happened.

  $ SPICE_MODEL=openai/gpt-5.5 spice run resume --last
  spice: run resume requires PROMPT when no turn is active
  [2]

A session with an active turn refuses a new prompt.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/running
  $ cat > $SPICE_TEST_DATA_HOME/sessions/running/session.json <<JSON
  > {"version":1,"id":"running","metadata":{"cwd":"$PWD","title":"Running","status":"active","created_at":1,"updated_at":2},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"Continue"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}}]}
  > JSON
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume running "another prompt"
  spice: run resume cannot accept PROMPT while a turn is active
  [2]

With --last, the extra positional is the prompt, and a second one is rejected.

  $ spice run resume --last "prompt" "extra"
  spice: run resume --last accepts at most one PROMPT
  [2]

Archived sessions refuse resume and hint the exact restore command; the
provider base URL points at a closed port, so a model call would fail
differently.

  $ spice session create --id parked --title Parked
  parked
  $ spice session archive parked
  parked
  $ OPENAI_API_KEY=test-key SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume --cwd "$PWD" parked "more work"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session is archived: parked
  Hint: restore it first: spice session restore 'parked'
  [1]

Deleted sessions are terminal.

  $ spice session create --id gone --title Gone
  gone
  $ spice session delete --yes gone
  gone
  $ OPENAI_API_KEY=test-key SPICE_OPENAI_BASE_URL=http://127.0.0.1:9/v1 spice run resume --cwd "$PWD" gone "more work"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: session is deleted: gone
  [1]

A live resume by id starts the next turn, runs it to completion, and the
saved hint names the interactive resume verb.

  $ cat > resume-live.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":["resumed prompt"]},"response":{"id":"resp-resume","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"resumed final answer"}]}]}}
  > JSONL
  $ start_fake_openai resume-live.jsonl capture-resume port-resume
  $ spice run resume --cwd "$PWD" idle-session "resumed prompt"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  resumed final answer
  spice: session saved; resume with: spice resume 'idle-session'
  $ wait_fake_server
  $ spice session show idle-session | grep '^preview'
  preview: resumed prompt
