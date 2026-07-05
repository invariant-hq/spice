Code-review-comment notices are produced by the CR watcher during a run. The
watcher's bounded initial scan seeds duplicate-suppression state silently, so a
notice is published only when an open CR comment appears or changes after the
run starts. Here the model rewrites a source file to carry an open CR comment
mid-turn; the shared filesystem watcher observes the change and the next model
request carries the injected code-review notice in its prelude.

A source file exists at run start without any CR comment, so the initial scan
records nothing for it and stays quiet.

  $ printf 'let x = 1\n' > note.ml

Only the code-review notice stream is enabled. The filesystem watcher still runs
(it is what drives the CR observer), but publishes no file-change notices of its
own, and the Dune notice streams are off, so the follow-up request body carries
the CR notice alone.

  $ spice config set notices.fswatch false
  $ spice config set notices.dune_build false
  $ spice config set notices.dune_diagnostics false
  $ spice config set notices.cr_comments true

The fake model rewrites the source file to contain an open CR comment, sleeping
around the write so the background filesystem watcher can observe the change
before the follow-up request is prepared.

  $ cat > cr.jsonl <<'JSONL'
  > {"expect":{"body_contains":["seed a review comment","\"name\":\"shell\""]},"response":{"id":"resp-cr-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cr","call_id":"call-cr","name":"shell","arguments":"{\"command\":\"sleep 1; printf '(* CR: tighten the parser *)\\\\n' > note.ml; sleep 4\",\"description\":\"seed an open CR comment\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-cr"]},"response":{"id":"resp-cr-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"noticed the review comment"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=12 start_fake_openai cr.jsonl cr-capture cr-port
  $ spice run --cwd "$PWD" --json --permission-mode bypass --id cr-live "seed a review comment" | grep -oE '"tool":"shell"|"final_text":"noticed the review comment"'
  spice: session saved; resume with: spice resume 'cr-live'
  "tool":"shell"
  "tool":"shell"
  "final_text":"noticed the review comment"
  $ wait_fake_server

The follow-up provider request carries the injected code-review notice: its
source, its warning severity, its title, and the open CR body scanned out of the
rewritten file.

  $ grep -oF 'source: code-review-comments' cr-capture/request-2.json
  source: code-review-comments
  $ grep -oF 'severity: warning' cr-capture/request-2.json
  severity: warning
  $ grep -oF 'title: Code review comments need attention' cr-capture/request-2.json
  title: Code review comments need attention
  $ grep -oF 'open now CR: tighten the parser' cr-capture/request-2.json
  open now CR: tighten the parser
