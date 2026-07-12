Skill resources: read through the tool, contained to the skill directory.

  $ git init -q .
  $ mkdir -p .spice/skills/demo
  $ cat > .spice/skills/demo/SKILL.md <<'EOF'
  > ---
  > description: A demo.
  > ---
  > See notes.md for details.
  > EOF
  $ printf 'the extra notes\n' > .spice/skills/demo/notes.md
  $ mkdir .spice/skills/demo/examples
  $ printf 'nested notes\n' > .spice/skills/demo/examples/nested.md
  $ printf 'secret outside\n' > outside.txt
  $ ln -s ../../../outside.txt .spice/skills/demo/escape.txt

Discovery advertises only immediate regular files that the resource reader can
actually open inside the skill root.

  $ spice skills show demo | sed -n '/^resources:/,/^$/p' | sed '/^$/d'
  resources:
    notes.md

The tool serves a resource file; an escaping symlink and a traversal path
are refused; builtins report product-facing guidance when a non-empty resource
is requested.

  $ cat > resources.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"skill\""]},"response":{"id":"r-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"i-1","call_id":"c-1","name":"skill","arguments":"{\"name\":\"demo\",\"resource\":\"notes.md\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","the extra notes"]},"response":{"id":"r-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"i-2","call_id":"c-2","name":"skill","arguments":"{\"name\":\"demo\",\"resource\":\"escape.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","path resolves outside workspace"],"body_not_contains":["secret outside"]},"response":{"id":"r-3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"i-3","call_id":"c-3","name":"skill","arguments":"{\"name\":\"demo\",\"resource\":\"../../../outside.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","path escapes root"],"body_not_contains":["secret outside"]},"response":{"id":"r-4","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"i-4","call_id":"c-4","name":"skill","arguments":"{\"name\":\"ocaml-tidy\",\"resource\":\"notes.md\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","skill \\\"ocaml-tidy\\\" has no resource files","call the skill tool without resource"]},"response":{"id":"r-5","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  $ start_fake_openai resources.jsonl capture-res port-res
  $ spice run --cwd "$PWD" --permission bypass --id res-run "read the resources"
  permission review: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  • tool skill running
  ✓ tool skill completed
  • tool skill running
  ✗ tool skill failed: escape.txt: path resolves outside workspace
  • tool skill running
  ✗ tool skill failed: path escapes root
  • tool skill running
  ✗ tool skill failed: skill "ocaml-tidy" has no resource files; call the skill tool without resource to load its guidance
  done
  spice: session saved; resume with: spice resume 'res-run'
  $ wait_fake_server

The refusal texts travel to the model as failed tool results, and the
escaped file's content never does: the fake server's expectations above
checked every request body.
