Filesystem notices are produced by the host watcher during a live run. A
mid-turn workspace change is reported to the next model request as a
`[spice notice]`, while default ignored path segments stay out of the notice
body.

Only filesystem notices are enabled so the follow-up request contains the file
change notice without CR-comment or Dune watcher noise.

  $ spice config set notices.fswatch true
  $ spice config set notices.cr_comments false
  $ spice config set notices.dune_build false
  $ spice config set notices.dune_diagnostics false

The fake model mutates one ordinary file and several ignored directories. The
sleep before the write gives the non-blocking watcher time to establish its
baseline; the sleep after the write gives the background watcher time to publish
the notice before the follow-up request is prepared.

  $ cat > fswatch.jsonl <<'JSONL'
  > {"expect":{"body_contains":["watch workspace changes","\"name\":\"shell\""]},"response":{"id":"resp-fswatch-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-fswatch","call_id":"call-fswatch","name":"shell","arguments":"{\"command\":\"sleep 1; printf watched > watched.txt; mkdir -p .git _build/default _opam/lib .spice src/.git; printf ignored > .git/config; printf ignored > _build/default/generated.ml; printf ignored > _opam/lib/pkg; printf ignored > .spice/session.json; printf ignored > src/.git/config; sleep 4\",\"description\":\"mutate watched and ignored paths\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-fswatch","source: fswatch","severity: info","title: Workspace files changed","created watched.txt"]},"response":{"id":"resp-fswatch-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"noticed filesystem change"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai fswatch.jsonl fswatch-capture fswatch-port
  $ spice run --cwd "$PWD" --json --permission-mode bypass --id fswatch-live "watch workspace changes" | grep -oE '"tool":"shell"|"final_text":"noticed filesystem change"'
  spice: session saved; resume with: spice resume 'fswatch-live'
  "tool":"shell"
  "tool":"shell"
  "final_text":"noticed filesystem change"
  $ wait_fake_server

The follow-up provider request carries the filesystem notice and the normal
path. Ignored directories may appear in the earlier shell command, but they do
not appear as watcher event lines in the notice body.

  $ grep -oF 'source: fswatch' fswatch-capture/request-2.json
  source: fswatch
  $ grep -oF 'severity: info' fswatch-capture/request-2.json
  severity: info
  $ grep -oF 'title: Workspace files changed' fswatch-capture/request-2.json
  title: Workspace files changed
  $ grep -oF 'created watched.txt' fswatch-capture/request-2.json
  created watched.txt
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
