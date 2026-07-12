Rewind can pair the transcript fork with a filesystem revert. With
--revert-fs the workspace is reverted to the rewind point, undoing the
dropped turns' Spice-authored file changes all-or-nothing, while the kept
turns' changes survive. The transcript rewind is always durable: a stale
file refuses only the filesystem half, and the child still exists.

The file-mutation editor is model-conditional (a GPT model receives the
apply_patch family, without edit_file/write_file), so these runs pin the
string-replace family explicitly; the model stays gpt-5.5 for the fake
OpenAI-Responses backend.

  $ spice config set tools.editor string-replace

A two-turn session: turn one edits fileA, turn two edits fileB. Each turn is
a separate run against its own fake backend cycle.

  $ printf 'aaa\n' > fileA.txt
  $ printf 'bbb\n' > fileB.txt

  $ cat > turn-a.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-a1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-a1","call_id":"call-a1","name":"edit_file","arguments":"{\"path\":\"fileA.txt\",\"old_string\":\"aaa\",\"new_string\":\"AAA\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-a1"]},"response":{"id":"resp-a2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited A"}]}]}}
  > JSONL

  $ start_fake_openai turn-a.jsonl cap-a port-a
  $ spice run --cwd "$PWD" --permission bypass --id rw "edit A" >/dev/null 2>&1
  $ wait_fake_server
  $ cat fileA.txt
  AAA

  $ cat > turn-b.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-b1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-b1","call_id":"call-b1","name":"edit_file","arguments":"{\"path\":\"fileB.txt\",\"old_string\":\"bbb\",\"new_string\":\"BBB\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-b1"]},"response":{"id":"resp-b2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited B"}]}]}}
  > JSONL

  $ start_fake_openai turn-b.jsonl cap-b port-b
  $ spice run resume rw --cwd "$PWD" --permission bypass "edit B" >/dev/null 2>&1
  $ wait_fake_server
  $ cat fileB.txt
  BBB

Turn ids are clock-derived, so name the second turn by extracting it from the
exported transcript (the last turn_started event).

  $ TURN2=$(spice session export rw | grep -oE '"turn_started"[^}]*"id":"turn_-?[0-9]+_[0-9]+_[0-9]+"' | tail -1 | grep -oE 'turn_-?[0-9]+_[0-9]+_[0-9]+')

Rewinding before the second turn with --revert-fs drops turn two, forks the
transcript to a child, and reverts fileB back to its pre-turn-two state.
fileA (turn one, kept) is untouched. A standing caveat states that the revert
only touches Spice-authored changes, never shell or manual edits.

  $ spice session rewind rw --to-turn "$TURN2" --before --revert-fs --id child
  child
  rewound rw: kept 1 dropped 1
  reverted 1 file in workspace
  warning: rewind does not affect files changed by shell commands or manual edits
  $ cat fileB.txt
  bbb
  $ cat fileA.txt
  AAA

The child transcript keeps only turn one; the parent is untouched.

  $ spice session show child | grep '^events:'
  events: 6
  $ spice session show rw | grep '^events:'
  events: 12

The child ledger records the revert: a diff over the child shows the inverse
edit that restored fileB, keyed into the child's own ledger.

  $ spice session diff child
  changed 1 file (+1 -1)
  M fileB.txt
  --- fileB.txt
  +++ fileB.txt
  @@ -1,1 +1,1 @@
  -BBB
  +bbb

A hand edit to a file the dropped turn touched makes the filesystem revert
refuse all-or-nothing: the file keeps the hand edit, the diagnostic is
reported, and the child transcript still exists because the rewind already
landed.

  $ printf 'ccc\n' > fileC.txt
  $ cat > turn-c.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-c1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-c1","call_id":"call-c1","name":"edit_file","arguments":"{\"path\":\"fileC.txt\",\"old_string\":\"ccc\",\"new_string\":\"CCC\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-c1"]},"response":{"id":"resp-c2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited C"}]}]}}
  > JSONL

  $ start_fake_openai turn-c.jsonl cap-c port-c
  $ spice run --cwd "$PWD" --permission bypass --id rw2 "edit C" >/dev/null 2>&1
  $ wait_fake_server
  $ cat fileC.txt
  CCC

  $ printf 'HANDEDIT\n' > fileC.txt
  $ TURNC=$(spice session export rw2 | grep -oE '"turn_started"[^}]*"id":"turn_-?[0-9]+_[0-9]+_[0-9]+"' | tail -1 | grep -oE 'turn_-?[0-9]+_[0-9]+_[0-9]+')

  $ spice session rewind rw2 --to-turn "$TURNC" --before --revert-fs --id child2 | sed -E 's/sha256:[0-9a-f]+/sha256:$HASH/'
  child2
  rewound rw2: kept 0 dropped 1
  stale fileC.txt: expected text(sha256:$HASH:4, 4 bytes)
  workspace not reverted; transcript rewind is durable

The file keeps the hand edit and the child transcript exists.

  $ cat fileC.txt
  HANDEDIT
  $ spice session show child2 | grep '^events:'
  events: 0
