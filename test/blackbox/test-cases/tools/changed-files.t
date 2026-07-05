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
  $ spice run --cwd "$PWD" --permission-mode bypass --id edit-run "change the greeting"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool edit_file running
  ✓ tool edit_file note.txt completed: M note.txt
  changed 1 file (+1 -1)
  diff: spice session diff edit-run --latest
  revert: spice session revert edit-run --latest
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

Revert previews by default and mutates nothing.

  $ spice session revert edit-run --latest
  would revert 1 file:
  M note.txt
  apply: spice session revert edit-run --latest --apply
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
  $ spice run --cwd "$PWD" --permission-mode bypass --id create-run "create the target file"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool write_file running
  ✓ tool write_file target.txt completed: A target.txt
  changed 1 file (+1 -0)
  diff: spice session diff create-run --latest
  revert: spice session revert create-run --latest
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
