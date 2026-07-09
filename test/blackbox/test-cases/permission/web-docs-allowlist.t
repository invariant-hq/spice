A curated set of read-only documentation hosts auto-allows web_fetch, so a
lookup does not prompt, while every other host still asks and the allowlist
never reaches a shell command. These are permission-layer facts, independent of
the sandbox, so the run stays unconfined (danger-full-access) to isolate them:
network is unmatched by the preset, so an arbitrary host reviews, and the shell
command halves prove the allowlist matches network accesses only.

  $ git init -q . 2>/dev/null
  $ spice config set web.enabled true
  $ spice config set web.timeout_ms 3000

An allowlisted documentation host is fetched with no permission wait: the run
completes and records no permission request. The fetch itself is bounded by the
web timeout and its outcome does not matter -- the decision precedes it.

  $ cat > docs.jsonl <<'JSONL'
  > {"expect":{"body_contains":["docs prompt","\"name\":\"web_fetch\""]},"response":{"id":"resp-docs-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-dc1","call_id":"call-dc1","name":"web_fetch","arguments":"{\"url\":\"https://docs.rs/\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-dc1"]},"response":{"id":"resp-docs-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"docs final"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=15 start_fake_openai docs.jsonl docs-capture docs-port
  $ spice run --cwd "$PWD" --sandbox danger-full-access --json --id docs-run "docs prompt" | grep -o '"outcome":"completed"'
  spice: session saved; resume with: spice resume 'docs-run'
  "outcome":"completed"
  $ wait_fake_server
  $ spice session export docs-run | grep -o '"type":"permission_requested"' || echo no-permission-requested
  no-permission-requested

An arbitrary host is not on the allowlist, so the web_fetch reviews: the run
parks on the permission and exits blocked before any fetch is attempted.

  $ cat > other.jsonl <<'JSONL'
  > {"expect":{"body_contains":["other prompt","\"name\":\"web_fetch\""]},"response":{"id":"resp-other-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-o1","call_id":"call-o1","name":"web_fetch","arguments":"{\"url\":\"https://example.com/\"}"}]}}
  > JSONL
  $ start_fake_openai other.jsonl other-capture other-port
  $ spice run --cwd "$PWD" --sandbox danger-full-access --id other-run "other prompt" >other.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'waiting: permission' other.out
  waiting: permission
  $ wait_fake_server

The allowlist credits web_fetch, not shell: a shell command reaching the same
documentation host is a command access the network-host rule never matches, so
it still reviews (and, under a sandbox, its network stays confined).

  $ cat > curl.jsonl <<'JSONL'
  > {"expect":{"body_contains":["curl prompt","\"name\":\"shell\""]},"response":{"id":"resp-curl-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-c1","call_id":"call-c1","name":"shell","arguments":"{\"command\":\"curl -sS https://docs.rs/\"}"}]}}
  > JSONL
  $ start_fake_openai curl.jsonl curl-capture curl-port
  $ spice run --cwd "$PWD" --sandbox danger-full-access --id curl-run "curl prompt" >curl.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'waiting: permission' curl.out
  waiting: permission
  $ wait_fake_server
