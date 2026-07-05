Anchored edits are V1 scope behind the tools.anchored_edits flag (default
off). With the flag off the catalog and read output are byte-identical to
today: edit_lines is unknown and reads carry no anchors. With the flag on,
read_file renders deterministic word-pair anchors seeded from the session id
and edit_lines applies all-or-nothing anchored batches that lower to the
same complete-text mutation waist as edit_file.

The file-mutation editor is model-conditional (a GPT model would receive the
apply_patch family, without edit_file/write_file). This case is about anchored
edits, not editor selection, so it pins the string-replace family explicitly;
the model stays gpt-5.5 for the fake OpenAI-Responses backend.

  $ spice config set tools.editor string-replace

Flag off: edit_lines is not in the catalog and reads have no anchors.

  $ printf 'alpha\nbeta\ngamma\ndelta\n' > note.txt
  $ cat > off.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"read_file\""]},"response":{"id":"resp-off-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-off-1","call_id":"call-off-1","name":"read_file","arguments":"{\"path\":\"note.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-off-1"]},"response":{"id":"resp-off-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-off-2","call_id":"call-off-2","name":"edit_lines","arguments":"{\"path\":\"note.txt\",\"edits\":[{\"op\":\"insert_after\",\"anchor\":\"PeonyWalnut§alpha\",\"text\":\"x\"}]}"}]}}
  > {"expect":{"body_contains":["unknown tool: edit_lines"]},"response":{"id":"resp-off-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"no anchored tools"}]}]}}
  > JSONL

  $ start_fake_openai off.jsonl capture-off port-off
  $ spice run --cwd "$PWD" --permission-mode bypass --id anchored-off "read the note"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool read_file running
  ✓ tool read_file note.txt completed: 4 lines
  no anchored tools
  spice: session saved; resume with: spice resume 'anchored-off'
  $ wait_fake_server

The flag-off read renders plain numbered lines, no anchors.

  $ grep -c "anchors=enabled" capture-off/request-2.json
  0
  [1]
  $ grep -o "unknown tool: edit_lines" capture-off/request-3.json
  unknown tool: edit_lines
  $ cat note.txt
  alpha
  beta
  gamma
  delta

Turn the flag on.

  $ spice config set tools.anchored_edits true
  $ spice config get tools.anchored_edits
  true

Flag on: reads render word-pair anchors, an overlapping batch is rejected,
one stale anchor fails the whole batch with expected-versus-provided text
and mutates nothing, and a valid bottom-up batch (replace plus insert)
applies in one call.

  $ cat > run.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_lines\"","\"name\":\"read_file\""]},"response":{"id":"resp-run-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-run-1","call_id":"call-run-1","name":"read_file","arguments":"{\"path\":\"note.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-run-1","anchors=enabled"]},"response":{"id":"resp-run-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-run-2","call_id":"call-run-2","name":"edit_lines","arguments":"{\"path\":\"note.txt\",\"edits\":[{\"op\":\"replace\",\"anchor\":\"PeonyWalnut§alpha\",\"end_anchor\":\"GazellePlum§gamma\",\"text\":\"ALL\"},{\"op\":\"replace\",\"anchor\":\"ElkSlate§beta\",\"end_anchor\":\"ElkSlate§beta\",\"text\":\"B\"}]}"}]}}
  > {"expect":{"body_contains":["overlapping edits"]},"response":{"id":"resp-run-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-run-3","call_id":"call-run-3","name":"edit_lines","arguments":"{\"path\":\"note.txt\",\"edits\":[{\"op\":\"replace\",\"anchor\":\"PeonyWalnut§alpha\",\"end_anchor\":\"PeonyWalnut§alpha\",\"text\":\"ALPHA\"},{\"op\":\"insert_after\",\"anchor\":\"ElkSlate§WRONG\",\"text\":\"x\"}]}"}]}}
  > {"expect":{"body_contains":["Provided"]},"response":{"id":"resp-run-4","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-run-4","call_id":"call-run-4","name":"edit_lines","arguments":"{\"path\":\"note.txt\",\"edits\":[{\"op\":\"replace\",\"anchor\":\"ElkSlate§beta\",\"end_anchor\":\"ElkSlate§beta\",\"text\":\"BETA\"},{\"op\":\"insert_after\",\"anchor\":\"GazellePlum§gamma\",\"text\":\"gamma2\"}]}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-run-4"]},"response":{"id":"resp-run-5","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"anchored edits applied"}]}]}}
  > JSONL

  $ start_fake_openai run.jsonl capture-run port-run
  $ spice run --cwd "$PWD" --permission-mode bypass --id anchored-run "apply the anchored edits"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool read_file running
  ✓ tool read_file note.txt completed: 4 lines
  • tool edit_lines running
  ✗ tool edit_lines failed: overlapping edits: lines 1-3 and 2-2; batch only non-overlapping edits
  • tool edit_lines running
  ✗ tool edit_lines failed: anchor: anchor "ElkSlate" exists, but the line text you provided does not match the file's content. Expected: "beta", Provided: "WRONG". Re-read the file to get current anchors and retry
  • tool edit_lines running
  ✓ tool edit_lines note.txt completed: M note.txt
  changed 1 file (+2 -1)
  diff: spice session diff anchored-run --latest
  revert: spice session revert anchored-run --latest
  anchored edits applied
  spice: session saved; resume with: spice resume 'anchored-run'
  $ wait_fake_server

The anchored read rendered deterministic word-pair anchors.

  $ grep -oE '1 [A-Za-z]+\\talpha' capture-run/request-2.json
  1 PeonyWalnut\talpha
  $ grep -oE '2 [A-Za-z]+\\tbeta' capture-run/request-2.json
  2 ElkSlate\tbeta

Only the valid batch mutated the file: the overlap rejection and the
all-or-nothing stale failure left it untouched, so the valid batch's
anchors still resolved.

  $ cat note.txt
  alpha
  BETA
  gamma
  gamma2
  delta

The change rows have the same shape as edit_file's: one modify row, netted
diff from the ledger, no model involved.

  $ spice session diff anchored-run --latest
  changed 1 file (+2 -1)
  M note.txt
  --- note.txt
  +++ note.txt
  @@ -1,4 +1,5 @@
   alpha
  -beta
  +BETA
   gamma
  +gamma2
   delta

Anchors are reconciled across edits inside one run: after an unrelated
edit_file inserts a line, a re-read keeps the anchors of unchanged lines
(same word, shifted line number) and assigns a fresh word to the new line.

  $ printf 'alpha\nbeta\ngamma\ndelta\n' > note2.txt
  $ cat > stable.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"read_file\""]},"response":{"id":"resp-stable-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-stable-1","call_id":"call-stable-1","name":"read_file","arguments":"{\"path\":\"note2.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-stable-1"]},"response":{"id":"resp-stable-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-stable-2","call_id":"call-stable-2","name":"edit_file","arguments":"{\"path\":\"note2.txt\",\"old_string\":\"alpha\",\"new_string\":\"alpha\\ninserted\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-stable-2"]},"response":{"id":"resp-stable-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-stable-3","call_id":"call-stable-3","name":"read_file","arguments":"{\"path\":\"note2.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-stable-3"]},"response":{"id":"resp-stable-4","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"anchors reconciled"}]}]}}
  > JSONL

  $ start_fake_openai stable.jsonl capture-stable port-stable
  $ spice run --cwd "$PWD" --permission-mode bypass --id anchored-stable "edit then re-read"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool read_file running
  ✓ tool read_file note2.txt completed: 4 lines
  • tool edit_file running
  ✓ tool edit_file note2.txt completed: M note2.txt
  • tool read_file running
  ✓ tool read_file note2.txt completed: 5 lines
  changed 1 file (+1 -0)
  diff: spice session diff anchored-stable --latest
  revert: spice session revert anchored-stable --latest
  anchors reconciled
  spice: session saved; resume with: spice resume 'anchored-stable'
  $ wait_fake_server

beta kept its anchor word across both reads even though it moved from line
2 to line 3; the inserted line received a fresh word.

  $ grep -oE '[0-9] [A-Za-z]+\\tbeta' capture-stable/request-2.json
  2 OspreyMoose\tbeta
  $ grep -oE '[0-9] [A-Za-z]+\\tbeta' capture-stable/request-4.json | sort -u
  2 OspreyMoose\tbeta
  3 OspreyMoose\tbeta
  $ grep -oE '[A-Za-z]+\\tbeta' capture-stable/request-4.json | sort -u
  OspreyMoose\tbeta
  $ grep -oE '[A-Za-z]+\\tinserted' capture-stable/request-4.json | sort -u
  KiwiJade\tinserted
