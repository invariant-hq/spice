The file-mutation editor family is model-conditional: a model trained on the
apply_patch format receives apply_patch alone; every other model receives
write_file plus edit_file. run/tools.t dumps each catalog in full; this case
pins the decision itself — the family a real run sends over the wire, the edit
it applies, and the tools.editor override that forces either family regardless
of the model.

Default under the GPT model: a run declares apply_patch and neither write_file
nor edit_file (the fake backend rejects a request whose body carries the wrong
family), and a scripted apply_patch edit applies for real.

  $ printf 'hello world\n' > note.txt
  $ cat > patch.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"apply_patch\""],"body_not_contains":["\"name\":\"write_file\"","\"name\":\"edit_file\""]},"response":{"id":"resp-patch-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-patch-1","call_id":"call-patch","name":"apply_patch","arguments":"{\"patch\":\"*** Begin Patch\\n*** Update File: note.txt\\n-hello world\\n+goodbye world\\n*** End Patch\\n\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-patch"]},"response":{"id":"resp-patch-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"patched"}]}]}}
  > JSONL
  $ start_fake_openai patch.jsonl capture-patch port-patch
  $ spice run --cwd "$PWD" --permission bypass --id patch-run "fix the greeting"
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool apply_patch running
  ✓ tool apply_patch note.txt completed: M note.txt
  changed 1 file (+1 -1)
  diff: spice session diff --latest 'patch-run'
  revert: spice session revert --latest 'patch-run'
  patched
  spice: session saved; resume with: spice resume 'patch-run'
  $ wait_fake_server

The patch applied to the real file.

  $ cat note.txt
  goodbye world

The edit is on the mutation ledger: session diff renders it without a model.

  $ spice session diff patch-run --latest
  changed 1 file (+1 -1)
  M note.txt
  --- note.txt
  +++ note.txt
  @@ -1,1 +1,1 @@
  -hello world
  +goodbye world

The tools.editor override forces a family regardless of the model. Set to
string-replace, even the GPT model's run catalog carries write_file and
edit_file and drops apply_patch, and the decision reason is the override, not
the capability.

  $ spice config set tools.editor string-replace
  $ spice debug tools --model openai/gpt-5.5 | grep -E '^Editor family|^## (write_file|edit_file|apply_patch)'
  Editor family: string-replace (override)
  ## write_file
  ## edit_file
  $ spice debug model --model openai/gpt-5.5 | grep '^editor:'
  editor: string-replace (override)

Set to apply-patch, a model that carries no apply_patch capability still
receives apply_patch alone — the override wins in the other direction too.

  $ spice config set tools.editor apply-patch
  $ spice debug tools --model anthropic/claude-opus-4-8 | grep -E '^Editor family|^## (write_file|edit_file|apply_patch)'
  Editor family: apply-patch (override)
  ## apply_patch
