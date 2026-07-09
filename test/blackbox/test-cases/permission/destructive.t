The shell tool marks a destructive command with a reviewable [shell.destructive]
access, so a review can single it out even where a sandbox otherwise backs
ordinary commands. Detection is a lenient scan over each program and its flags;
a benign command carries no such access. These runs use the harness default
danger-full-access posture, where every command is reviewed, so the marker's
presence or absence is visible in the block regardless of platform.

A recursive force delete is flagged.

  $ cat > rm.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-rm","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-rm","call_id":"call-rm","name":"shell","arguments":"{\"command\":\"rm -rf build\"}"}]}}
  > JSONL
  $ start_fake_openai rm.jsonl rm-capture rm-port
  $ spice run --cwd "$PWD" --id d-rm "rm" >rm.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'custom shell.destructive' rm.out
  custom shell.destructive
  $ wait_fake_server

A force push is flagged, and the scan reads the git subcommand rather than the
bare program.

  $ cat > push.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-push","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-push","call_id":"call-push","name":"shell","arguments":"{\"command\":\"git push --force origin main\"}"}]}}
  > JSONL
  $ start_fake_openai push.jsonl push-capture push-port
  $ spice run --cwd "$PWD" --id d-push "push" >push.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'custom shell.destructive' push.out
  custom shell.destructive
  $ wait_fake_server

Privilege escalation leaves the confinement entirely, so it is flagged.

  $ cat > sudo.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-sudo","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-sudo","call_id":"call-sudo","name":"shell","arguments":"{\"command\":\"sudo systemctl restart nginx\"}"}]}}
  > JSONL
  $ start_fake_openai sudo.jsonl sudo-capture sudo-port
  $ spice run --cwd "$PWD" --id d-sudo "sudo" >sudo.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'custom shell.destructive' sudo.out
  custom shell.destructive
  $ wait_fake_server

A read-only git subcommand is not flagged.

  $ cat > status.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-status","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-status","call_id":"call-status","name":"shell","arguments":"{\"command\":\"git status\"}"}]}}
  > JSONL
  $ start_fake_openai status.jsonl status-capture status-port
  $ spice run --cwd "$PWD" --id d-status "status" >status.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'shell.destructive' status.out || echo no-marker
  no-marker
  $ wait_fake_server

A plain listing is not flagged.

  $ cat > ls.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"shell\""]},"response":{"id":"resp-ls","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-ls","call_id":"call-ls","name":"shell","arguments":"{\"command\":\"ls -la\"}"}]}}
  > JSONL
  $ start_fake_openai ls.jsonl ls-capture ls-port
  $ spice run --cwd "$PWD" --id d-ls "ls" >ls.out 2>&1; echo exit:$?
  exit:3
  $ grep -o 'shell.destructive' ls.out || echo no-marker
  no-marker
  $ wait_fake_server
