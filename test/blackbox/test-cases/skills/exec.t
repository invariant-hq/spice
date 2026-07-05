The skill tool and --skill injection through the real exec loop with the
fake provider.

  $ git init -q .

The model sees the skill tool with the catalog in its description and loads
a builtin skill; the tool result carries the skill text into the transcript.

  $ cat > load.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"skill\"","Available skills:","ocaml-tidy"]},"response":{"id":"resp-skill-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-skill-1","call_id":"call-skill-1","name":"skill","arguments":"{\"name\":\"ocaml-tidy\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-skill-1","Tidying is disciplined implementation editing"]},"response":{"id":"resp-skill-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"loaded the skill"}]}]}}
  > JSONL
  $ start_fake_openai load.jsonl capture-load port-load
  $ spice run --cwd "$PWD" --permission-mode bypass --id skill-run "tidy this code"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool skill running
  ✓ tool skill completed
  loaded the skill
  spice: session saved; resume with: spice resume 'skill-run'
  $ wait_fake_server

Providers sometimes serialize absent optional string fields as empty strings.
For skill resources, the empty string is treated as absent so the call still
loads the skill body instead of trying to read a non-existent resource.

  $ cat > empty-resource.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"skill\""]},"response":{"id":"resp-empty-resource-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-empty-resource-1","call_id":"call-empty-resource-1","name":"skill","arguments":"{\"name\":\"ocaml-tidy\",\"resource\":\"\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-empty-resource-1","Tidying is disciplined implementation editing"]},"response":{"id":"resp-empty-resource-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"loaded empty resource skill"}]}]}}
  > JSONL
  $ start_fake_openai empty-resource.jsonl capture-empty-resource port-empty-resource
  $ spice run --cwd "$PWD" --permission-mode bypass --id empty-resource-run "tidy this code with empty resource"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool skill running
  ✓ tool skill completed
  loaded empty resource skill
  spice: session saved; resume with: spice resume 'empty-resource-run'
  $ wait_fake_server

An unknown skill name in the tool call is a failed tool result, not a crash.

  $ cat > unknown.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"skill\""]},"response":{"id":"resp-unk-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-unk-1","call_id":"call-unk-1","name":"skill","arguments":"{\"name\":\"nope\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","unknown skill"]},"response":{"id":"resp-unk-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"no such skill"}]}]}}
  > JSONL
  $ start_fake_openai unknown.jsonl capture-unknown port-unknown
  $ spice run --cwd "$PWD" --permission-mode bypass --id unknown-run "use a missing skill"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool skill running
  ✗ tool skill failed: unknown skill "nope"; available skills: ocaml-benchmarking, ocaml-concurrency, ocaml-debug, ocaml-doc, ocaml-dune, ocaml-ffi, ocaml-library-design, ocaml-module-design, ocaml-perf, ocaml-project-setup, ocaml-release, ocaml-testing, ocaml-tidy
  no such skill
  spice: session saved; resume with: spice resume 'unknown-run'
  $ wait_fake_server

--skill places the labeled skill text ahead of the prompt in the turn's
user message, durably.

  $ cat > forced.jsonl <<'JSONL'
  > {"expect":{"body_contains":["The user invoked the","Tidying is disciplined implementation editing","tidy my file"]},"response":{"id":"resp-forced-1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"followed the skill"}]}]}}
  > JSONL
  $ start_fake_openai forced.jsonl capture-forced port-forced
  $ spice run --cwd "$PWD" --permission-mode bypass --id forced-run --skill ocaml-tidy "tidy my file"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  followed the skill
  spice: session saved; resume with: spice resume 'forced-run'
  $ wait_fake_server

The injected skill text is durable transcript state, visible in the saved
session.

  $ spice session show --json forced-run | grep -c 'The user invoked'
  1

--skill with an unknown name fails before any model call.

  $ spice run --cwd "$PWD" --skill nope "prompt" 2>&1 | tail -1
  spice: unknown skill "nope"; available skills: ocaml-benchmarking, ocaml-concurrency, ocaml-debug, ocaml-doc, ocaml-dune, ocaml-ffi, ocaml-library-design, ocaml-module-design, ocaml-perf, ocaml-project-setup, ocaml-release, ocaml-testing, ocaml-tidy
  [2]

--no-skills removes the tool from the request entirely.

  $ cat > noskills.jsonl <<'JSONL'
  > {"expect":{"body_not_contains":["\"name\":\"skill\"","Available skills:"]},"response":{"id":"resp-ns-1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"no skills here"}]}]}}
  > JSONL
  $ start_fake_openai noskills.jsonl capture-ns port-ns
  $ spice run --cwd "$PWD" --permission-mode bypass --no-skills --id ns-run "plain run"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  no skills here
  spice: session saved; resume with: spice resume 'ns-run'
  $ wait_fake_server
