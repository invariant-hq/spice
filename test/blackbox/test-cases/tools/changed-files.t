Changed-file evidence, diff, and revert are product surfaces over the
mutation ledger. They are exercised through the public CLI with the fake
provider; no checkpoint backend exists here because the test directory is
not a git repository, which also proves the ledger works backend-less.

An edit_file run records a change row, prints the changed trailer with the
diff/revert hints, and `spice session diff` renders the evidence without
asking a model.

The file-mutation editor is model-conditional (a GPT model receives the
apply_patch family, without edit_file/write_file), so these runs pin the
string-replace family explicitly; the model stays gpt-5.5 for the fake
OpenAI-Responses backend.

  $ spice config set tools.editor string-replace

  $ printf 'hello world\n' > note.txt
  $ cat > edit.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-edit-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-edit-1","call_id":"call-edit-1","name":"edit_file","arguments":"{\"path\":\"note.txt\",\"old_string\":\"hello\",\"new_string\":\"goodbye\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-edit-1"]},"response":{"id":"resp-edit-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited"}]}]}}
  > JSONL

  $ start_fake_openai edit.jsonl capture-edit port-edit
  $ spice run --cwd "$PWD" --permission bypass --id edit-run "change the greeting"
  permission review: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool edit_file running
  ✓ tool edit_file note.txt completed: M note.txt
  changed 1 file (+1 -1)
  diff: spice session diff --latest 'edit-run'
  revert: spice session revert --latest 'edit-run'
  edited
  spice: session saved; resume with: spice resume 'edit-run'
  $ wait_fake_server
  $ cat note.txt
  goodbye world

  $ spice session diff edit-run --latest
  changed 1 file (+1 -1)
  M note.txt
  --- note.txt
  +++ note.txt
  @@ -1,1 +1,1 @@
  -hello world
  +goodbye world

Diff is model-independent and structured under --json.

  $ spice session diff --json edit-run --latest | sed -E 's/"sources":\[[^]]*\]/"sources":["$ID"]/'
  {"schema_version":1,"type":"session.diff","session_id":"edit-run","files":1,"additions":1,"deletions":1,"changes":[{"path":"note.txt","operation":"M","contiguous":true,"sources":["$ID"]}],"diff":"--- note.txt\n+++ note.txt\n@@ -1,1 +1,1 @@\n-hello world\n+goodbye world\n"}

Failed edit_file calls report tool failures to the model, leave the file
unchanged, and do not record changed-file evidence for a failed-only run.

  $ printf 'red red blue\n' > fail.txt
  $ cat > edit-fail.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-fail-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-fail-1","call_id":"call-fail-1","name":"edit_file","arguments":"{\"path\":\"fail.txt\",\"old_string\":\"missing\",\"new_string\":\"green\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-fail-1","old_string was not found"]},"response":{"id":"resp-fail-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-fail-2","call_id":"call-fail-2","name":"edit_file","arguments":"{\"path\":\"fail.txt\",\"old_string\":\"red\",\"new_string\":\"green\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-fail-2","matched 2 times"]},"response":{"id":"resp-fail-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-fail-3","call_id":"call-fail-3","name":"edit_file","arguments":"{\"path\":\"fail.txt\",\"old_string\":\"red\",\"new_string\":\"green\",\"occurrence\":\"many\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-fail-3","occurrence"]},"response":{"id":"resp-fail-4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edit failures reported"}]}]}}
  > JSONL

  $ start_fake_openai edit-fail.jsonl capture-fail port-fail
  $ spice run --cwd "$PWD" --permission bypass --id edit-fail-run "try failing edits" > edit-fail.out 2>&1
  $ sed -n '/tool edit_file/p;/edit failures reported/p;/session saved/p' edit-fail.out
  • tool edit_file running
  ✗ tool edit_file failed: fail.txt: old_string was not found
  • tool edit_file running
  ✗ tool edit_file failed: fail.txt: old_string matched 2 times; provide more context or set occurrence=all
  edit failures reported
  spice: session saved; resume with: spice resume 'edit-fail-run'
  $ wait_fake_server
  $ grep -c '^changed ' edit-fail.out || true
  0
  $ cat fail.txt
  red red blue

A failed mutation-ledger rename removes the temporary file. The target is a
directory here solely to force the real atomic-write failure; mutation evidence
degrades without changing the model run.

  $ mkdir -p "$SPICE_TEST_DATA_HOME/sessions/mutation-cleanup/mutations.jsonl"
  $ cat > mutation-cleanup.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-cleanup-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-cleanup-1","call_id":"call-cleanup-1","name":"write_file","arguments":"{\"path\":\"cleanup.txt\",\"contents\":\"cleaned\\n\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-cleanup-1"]},"response":{"id":"resp-cleanup-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"cleanup exercised"}]}]}}
  > JSONL
  $ start_fake_openai mutation-cleanup.jsonl capture-cleanup port-cleanup
  $ spice run --cwd "$PWD" --permission bypass --id mutation-cleanup "force ledger rename failure" > /dev/null 2>&1
  $ wait_fake_server
  $ find "$SPICE_TEST_DATA_HOME/sessions/mutation-cleanup" -name 'mutations.jsonl.tmp.*' | wc -l | tr -d ' '
  0

Runtime paths that need escaping remain display-safe in diff headers.

  $ cat > newline-path.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-newline-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-newline-1","call_id":"call-newline-1","name":"write_file","arguments":"{\"path\":\"bad\\nname.txt\",\"contents\":\"odd\\n\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-newline-1"]},"response":{"id":"resp-newline-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"created newline path"}]}]}}
  > JSONL

  $ start_fake_openai newline-path.jsonl capture-newline port-newline
  $ spice run --cwd "$PWD" --permission bypass --id newline-path-run "create the newline path" > newline-run.out 2>&1
  $ sed -n '/^changed /p;/^diff:/p;/^spice:/p' newline-run.out
  changed 1 file (+1 -0)
  diff: spice session diff --latest 'newline-path-run'
  spice: session saved; resume with: spice resume 'newline-path-run'
  $ wait_fake_server

  $ spice session diff newline-path-run --latest | grep -E '^(changed|---|[+][+][+]|[+]odd)'
  changed 1 file (+1 -0)
  --- /dev/null
  +++ bad\nname.txt
  +odd
  $ spice session diff --json newline-path-run --latest | sed -E 's/"sources":\[[^]]*\]/"sources":["$ID"]/' | grep -o '"diff":"[^"]*"'
  "diff":"--- /dev/null\n+++ bad\\nname.txt\n@@ -0,0 +1,1 @@\n+odd\n"

Revert previews by default and mutates nothing.

  $ spice session revert edit-run --latest
  would revert 1 file:
  M note.txt
  apply: spice session revert --latest --apply 'edit-run'
  $ cat note.txt
  goodbye world

Applying the revert restores the file, records revert audit rows, and the
netted diff for the turn becomes empty.

  $ spice session revert edit-run --latest --apply
  reverted 1 file
  $ cat note.txt
  hello world
  $ spice session diff edit-run --latest
  changed 0 files (+0 -0)

A stale workspace refuses the revert loudly and changes nothing.

  $ printf 'created by spice\n' > target.txt && rm target.txt
  $ cat > create.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"write_file\""]},"response":{"id":"resp-create-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-create-1","call_id":"call-create-1","name":"write_file","arguments":"{\"path\":\"target.txt\",\"contents\":\"created by spice\\n\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-create-1"]},"response":{"id":"resp-create-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"created"}]}]}}
  > JSONL

  $ start_fake_openai create.jsonl capture-create port-create
  $ spice run --cwd "$PWD" --permission bypass --id create-run "create the target file"
  permission review: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool write_file running
  ✓ tool write_file target.txt completed: A target.txt
  changed 1 file (+1 -0)
  diff: spice session diff --latest 'create-run'
  revert: spice session revert --latest 'create-run'
  created
  spice: session saved; resume with: spice resume 'create-run'
  $ wait_fake_server

  $ printf 'drifted\n' > target.txt
  $ spice session revert create-run --latest
  would revert 0 files:
  stale target.txt: expected text(sha256:6fb6b024d196c1cf80d67d67cfe1f623a61f9b4af6383a99ab040680015e4174:17, 17 bytes)
  $ spice session revert create-run --latest --apply
  stale target.txt: expected text(sha256:6fb6b024d196c1cf80d67d67cfe1f623a61f9b4af6383a99ab040680015e4174:17, 17 bytes)
  spice: revert refused; no files were changed
  [1]
  $ cat target.txt
  drifted

Reverting the created file when the workspace still matches deletes it.

  $ printf 'created by spice\n' > target.txt
  $ spice session revert create-run --latest --apply
  reverted 1 file
  $ test -e target.txt || echo "target.txt removed"
  target.txt removed
