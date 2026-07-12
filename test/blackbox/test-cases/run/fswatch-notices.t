Filesystem notices are produced by the host watcher during a live run. A
mid-turn workspace change is reported to the next model request as a
`[spice notice]`, while default ignored path segments stay out of the notice
body.

Only filesystem notices are enabled so the follow-up request contains the file
change notice without CR-comment or Dune watcher noise.

  $ mkdir -p workspace/src
  $ git -C workspace init -q
  $ printf 'external.txt\n' > workspace/.gitignore
  $ spice trust workspace > /dev/null
  $ spice config set notices.fswatch true
  $ spice config set notices.cr_comments false
  $ spice config set notices.dune_build false
  $ spice config set notices.dune_diagnostics false

The fake model mutates one ordinary file and several ignored directories. The
sleep before the write gives the non-blocking watcher time to establish its
baseline; the sleep after the write gives the background watcher time to observe
the batch while the mutating claim is still active. The follow-up request must
carry the tool result but no filesystem notice for the tool's own paths.

  $ cat > fswatch.jsonl <<'JSONL'
  > {"expect":{"body_contains":["watch workspace changes","\"name\":\"shell\""]},"response":{"id":"resp-fswatch-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-fswatch","call_id":"call-fswatch","name":"shell","arguments":"{\"command\":\"sleep 1; printf watched > watched.txt; mkdir -p .git _build/default _opam/lib .spice src/.git; printf ignored > .git/agent-ignored; printf ignored > _build/default/generated.ml; printf ignored > _opam/lib/pkg; printf ignored > .spice/session.json; printf ignored > src/.git/config; sleep 4\",\"description\":\"mutate watched and ignored paths\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-fswatch","source: fswatch","title: Workspace files changed","created external.txt"],"body_not_contains":["created watched.txt"]},"response":{"id":"resp-fswatch-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"finished own change"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai fswatch.jsonl fswatch-capture fswatch-port
  $ (sleep 2; printf external > workspace/external.txt) & concurrent_external_pid=$!
  $ spice run --cwd "$PWD/workspace" --json --permission bypass --id fswatch-live "watch workspace changes" | grep -oE '"tool":"shell"|"final_text":"finished own change"'
  spice: session saved; resume with: spice resume 'fswatch-live'
  "tool":"shell"
  "tool":"shell"
  "final_text":"finished own change"
  $ wait "$concurrent_external_pid"
  $ wait_fake_server

The follow-up provider request carries the concurrent external write but not the
agent's own write. Ignored directories may appear in the earlier shell command,
but they do not appear as watcher event lines either.

  $ grep -oF 'source: fswatch' fswatch-capture/request-2.json | head -1
  source: fswatch
  $ grep -oF 'created external.txt' fswatch-capture/request-2.json
  created external.txt
  $ grep -oF 'created watched.txt' fswatch-capture/request-2.json || echo no-own-event
  no-own-event
  $ grep -oF 'created .git' fswatch-capture/request-2.json || echo no-git-events
  no-git-events
  $ grep -oF 'created _build' fswatch-capture/request-2.json || echo no-build-events
  no-build-events
  $ grep -oF 'created _opam' fswatch-capture/request-2.json || echo no-opam-events
  no-opam-events
  $ grep -oF 'created .spice' fswatch-capture/request-2.json || echo no-spice-events
  no-spice-events
  $ grep -oF 'created src/.git' fswatch-capture/request-2.json || echo no-nested-git-events
  no-nested-git-events

An external write remains visible. The provider delays its first response while
the background process writes; a read-only tool then creates the next request
boundary, where the queued notice must contain the external path.

  $ rm workspace/external.txt
  $ printf seed > workspace/seed.txt
  $ cat > fswatch-external.jsonl <<'JSONL'
  > {"delay_ms":2000,"expect":{"body_contains":["watch an external change","\"name\":\"read_file\""]},"response":{"id":"resp-external-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-external","call_id":"call-external","name":"read_file","arguments":"{\"path\":\"seed.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-external","source: fswatch","title: Workspace files changed","created external.txt"],"body_not_contains":["created watched.txt"]},"response":{"id":"resp-external-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"noticed external change"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai fswatch-external.jsonl fswatch-external-capture fswatch-external-port
  $ (sleep 1; printf external > workspace/external.txt) & external_pid=$!
  $ spice run --cwd "$PWD/workspace" --json --permission bypass --id fswatch-external "watch an external change" | grep -oE '"tool":"read_file"|"final_text":"noticed external change"'
  spice: session saved; resume with: spice resume 'fswatch-external'
  "tool":"read_file"
  "tool":"read_file"
  "final_text":"noticed external change"
  $ wait "$external_pid"
  $ wait_fake_server
  $ grep -oF 'created external.txt' fswatch-external-capture/request-2.json
  created external.txt
  $ grep -oF 'created watched.txt' fswatch-external-capture/request-2.json || echo no-stale-own-event
  no-stale-own-event
