The shadow-git checkpoint backend bounds shell attribution to the run
window. The workspace is a git repository in a subdirectory so the session
store (under the test HOME) stays outside the snapshots. Exec stderr is
captured separately so stdout assertions cannot race the saved hint.

  $ mkdir repo && git init --quiet repo
  $ printf 'hello world\n' > repo/note.txt

The file-mutation editor is model-conditional (a GPT model receives the
apply_patch family, without edit_file/write_file), so these runs pin the
string-replace family explicitly; the model stays gpt-5.5 for the fake
OpenAI-Responses backend.

  $ spice config set tools.editor string-replace

A run that edits a file and then mutates the workspace through shell records
a typed change row for the edit, a lazy checkpoint before it, and a run-end
checkpoint when the turn finishes because shell ran.

  $ cat > mixed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-mixed-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-mixed-1","call_id":"call-mixed-1","name":"edit_file","arguments":"{\"path\":\"note.txt\",\"old_string\":\"hello\",\"new_string\":\"goodbye\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-mixed-1"]},"response":{"id":"resp-mixed-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-mixed-2","call_id":"call-mixed-2","name":"shell","arguments":"{\"command\":\"echo drift > unattributed.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-mixed-2"]},"response":{"id":"resp-mixed-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"mixed done"}]}]}}
  > JSONL

  $ start_fake_openai mixed.jsonl capture-mixed port-mixed
  $ spice run --cwd "$PWD/repo" --permission-mode bypass --id mixed-run "edit then shell" 2>mixed.err | sed -E 's/exited 0 in [0-9.]+s/exited 0 in $TIME/'
  • tool edit_file running
  ✓ tool edit_file note.txt completed: M note.txt
  • tool shell running
  ✓ tool shell "echo drift > unattributed.txt" exited 0 in $TIME
  changed 1 file (+1 -1)
  diff: spice session diff --latest 'mixed-run'
  revert: spice session revert --latest 'mixed-run'
  mixed done
  $ grep "session saved" mixed.err
  spice: session saved; resume with: spice resume 'mixed-run'
  $ wait_fake_server
  $ cat repo/note.txt
  goodbye world
  $ cat repo/unattributed.txt
  drift
  $ find "$SPICE_TEST_DATA_HOME/workspaces" -name workspace.json | wc -l | tr -d ' '
  1
  $ find "$SPICE_TEST_DATA_HOME/workspaces" -type d -name checkpoints.git | wc -l | tr -d ' '
  1
  $ test ! -e repo/.spice && echo no-project-state
  no-project-state

Diff renders the typed change and attributes the shell-created path from
the bounded checkpoint pair, marked as not revertable.

  $ spice session diff --cwd "$PWD/repo" mixed-run --latest
  changed 1 file (+1 -1)
  M note.txt
  --- note.txt
  +++ note.txt
  @@ -1,1 +1,1 @@
  -hello world
  +goodbye world
  changed during run (unattributed; not revertable): unattributed.txt

The typed revert previews against the live workspace and ignores the
unattributed shell file.

  $ spice session revert --cwd "$PWD/repo" mixed-run --latest
  would revert 1 file:
  M note.txt
  apply: spice session revert --latest --apply 'mixed-run'

A run without shell in the same workspace gets no unattributed section and
no degraded note.

  $ cat > editonly.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-eo-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-eo-1","call_id":"call-eo-1","name":"edit_file","arguments":"{\"path\":\"note.txt\",\"old_string\":\"goodbye\",\"new_string\":\"farewell\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-eo-1"]},"response":{"id":"resp-eo-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited again"}]}]}}
  > JSONL

  $ start_fake_openai editonly.jsonl capture-eo port-eo
  $ spice run --cwd "$PWD/repo" --permission-mode bypass --id edit-only "edit only" 2>/dev/null
  • tool edit_file running
  ✓ tool edit_file note.txt completed: M note.txt
  changed 1 file (+1 -1)
  diff: spice session diff --latest 'edit-only'
  revert: spice session revert --latest 'edit-only'
  edited again
  $ wait_fake_server

  $ spice session diff --cwd "$PWD/repo" edit-only --latest
  changed 1 file (+1 -1)
  M note.txt
  --- note.txt
  +++ note.txt
  @@ -1,1 +1,1 @@
  -goodbye world
  +farewell world

After the later edit-only run, the older run's revert is stale and refuses.

  $ spice session revert --cwd "$PWD/repo" mixed-run --latest --apply 2>&1 | sed -E 's/sha256:[0-9a-f]+/sha256:$HASH/'; echo "exit:${PIPESTATUS[0]}"
  stale note.txt: expected text(sha256:$HASH:14, 14 bytes)
  spice: revert refused; no files were changed
  exit:1
  $ cat repo/note.txt
  farewell world
