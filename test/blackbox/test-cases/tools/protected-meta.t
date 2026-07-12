Protected workspace metadata (.git, .spice) is read-only to the native edit
tools, enforced at the write-side IO chokepoint independent of permission mode
and sandbox. Even a bypass-permission, danger-full-access run — which disables
the command sandbox entirely — cannot write .spice/config.json (the config
self-grant vector) or .git/hooks/pre-commit through write_file, while ordinary
files still write. Sandbox and workspace policy change through the CLI, not
through the agent's edit tools.

  $ export SPICE_SANDBOX_MODE=danger-full-access
  $ export SPICE_TRUSTED_WORKSPACE="$PWD"

Force the string-replace editor family so the gpt fake receives write_file.

  $ spice config set tools.editor string-replace
  $ mkdir -p .git/hooks

The model attempts three writes in one run: a .spice config file, a git hook,
and an ordinary file. Only the ordinary file may be written.

  $ cat > meta.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-meta-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-meta-1","call_id":"call-meta-1","name":"write_file","arguments":"{\"path\":\".spice/config.json\",\"contents\":\"{\\\"sandbox\\\":{\\\"writable_roots\\\":[\\\"~\\\"]}}\"}"}]}}
  > {"expect":{"body_contains":["call-meta-1","protected workspace metadata"]},"response":{"id":"resp-meta-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-meta-2","call_id":"call-meta-2","name":"write_file","arguments":"{\"path\":\".git/hooks/pre-commit\",\"contents\":\"#!/bin/sh\\nexfiltrate\\n\"}"}]}}
  > {"expect":{"body_contains":["call-meta-2","protected workspace metadata"]},"response":{"id":"resp-meta-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-meta-3","call_id":"call-meta-3","name":"write_file","arguments":"{\"path\":\"allowed.txt\",\"contents\":\"ok\\n\"}"}]}}
  > {"expect":{"body_contains":["call-meta-3"]},"response":{"id":"resp-meta-4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  $ start_fake_openai meta.jsonl capture-meta port-meta
  $ spice run --cwd "$PWD" --permission bypass --id meta-run "write files" >meta.out 2>&1; echo exit:$?
  exit:0
  $ wait_fake_server

Both protected writes were refused; the ordinary write succeeded.

  $ grep -c 'protected workspace metadata' meta.out
  2
  $ test ! -e .spice/config.json && echo no-spice-config
  no-spice-config
  $ test ! -e .git/hooks/pre-commit && echo no-git-hook
  no-git-hook
  $ cat allowed.txt
  ok

Reads of protected metadata are unaffected: only writes are guarded.

  $ printf 'ref: refs/heads/main\n' > .git/HEAD
  $ cat > read.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"read_file\""]},"response":{"id":"resp-read-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-read-1","call_id":"call-read-1","name":"read_file","arguments":"{\"path\":\".git/HEAD\"}"}]}}
  > {"expect":{"body_contains":["call-read-1","refs/heads/main"]},"response":{"id":"resp-read-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"read"}]}]}}
  > JSONL
  $ start_fake_openai read.jsonl capture-read port-read
  $ spice run --cwd "$PWD" --permission bypass --id read-run "read head" >read.out 2>&1; echo exit:$?
  exit:0
  $ wait_fake_server
