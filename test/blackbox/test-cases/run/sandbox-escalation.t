The headless escalation round-trip: under the default permission mode an
escalating shell call blocks the run with a reviewable permission, an
explicit continuation approves it, and the approved command runs unconfined
with not_requested evidence. Approved escalation needs no backend, so the
flow is deterministic on every platform via the seam.

  $ export SPICE_SANDBOX_MODE=workspace-write
  $ export SPICE_SANDBOX_REQUIRE=off
  $ export _SPICE_TEST_SANDBOX_UNAVAILABLE=1
  $ export SPICE_TRUSTED_WORKSPACE="$PWD"

  $ cat > escalate-start.jsonl <<'JSONL'
  > {"expect":{"body_contains":["escalate prompt","\"name\":\"shell\""]},"response":{"id":"resp-esc-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-esc-1","call_id":"call-esc-1","name":"shell","arguments":"{\"command\":\"printf esc-one\",\"escalate\":true,\"description\":\"sandbox blocked the previous attempt\"}"}]}}
  > JSONL
  $ start_fake_openai escalate-start.jsonl esc-capture-start esc-port-start

  $ spice run --cwd "$PWD" --id esc-run "escalate prompt" >esc-block.out 2>&1; echo exit:$?
  exit:3
  $ sed -E "s/perm:[^ ']+/perm:\$ID/g; s/turn=turn_[^ ]+/turn=turn_\$ID/g" esc-block.out
  permission: default
  sandbox: workspace-write (config)
  backend: none refused
  network: restricted
  spice: session esc-run waiting: permission perm:$ID tool=shell turn=turn_$ID call=call-esc-1
  mode: default
  action: 'printf esc-one'
  accesses:
  - command exec 'printf' 'esc-one'  [review: no rule or grant]
  - custom shell.escalate 'printf esc-one'  [review: no rule or grant]
  allow once: spice run reply 'esc-run' --allow 'perm:$ID'
  allow conversation: spice run reply 'esc-run' --allow-conversation 'perm:$ID'
  deny: spice run reply 'esc-run' --deny 'perm:$ID'
  deny with message: spice run reply 'esc-run' --deny 'perm:$ID' --message TEXT|-
  $ wait_fake_server

The durable request carries the distinct escalation access alongside the
command access, and nothing ran before approval.

  $ spice session export esc-run | grep -o '"type":"permission_requested"'
  "type":"permission_requested"
  $ spice session export esc-run | grep -o 'shell.escalate'
  shell.escalate
  shell.escalate
  $ spice session export esc-run | grep -c '"type":"tool_claim_started"'
  0
  [1]

Approving with --allow-conversation executes that one command unconfined: the
provider sees the output with not_requested evidence, and the next response
escalates a different command — which must block again, because session
grants cover only the identical command. Escalation approval never
broadens.

  $ permission_id=$(spice session show --json esc-run | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ cat > escalate-next.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","call-esc-1","esc-one","not_requested"]},"response":{"id":"resp-esc-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-esc-2","call_id":"call-esc-2","name":"shell","arguments":"{\"command\":\"printf esc-two\",\"escalate\":true,\"description\":\"second escalation\"}"}]}}
  > JSONL
  $ start_fake_openai escalate-next.jsonl esc-capture-next esc-port-next
  $ spice run reply esc-run --cwd "$PWD" --allow-conversation "$permission_id" >esc-next.out 2>&1; echo exit:$?
  exit:3
  $ sed -E "s/perm:[^ ']+/perm:\$ID/g; s/turn=turn_[^ ]+/turn=turn_\$ID/g" esc-next.out
  permission: default
  sandbox: workspace-write (config)
  backend: none refused
  network: restricted
  • tool shell running
  ✓ tool shell "printf esc-one" exited 0 in 0.0s
  spice: session esc-run waiting: permission perm:$ID tool=shell turn=turn_$ID call=call-esc-2
  mode: default
  action: 'printf esc-two'
  accesses:
  - command exec 'printf' 'esc-two'  [review: no rule or grant]
  - custom shell.escalate 'printf esc-two'  [review: no rule or grant]
  allow once: spice run reply 'esc-run' --allow 'perm:$ID'
  allow conversation: spice run reply 'esc-run' --allow-conversation 'perm:$ID'
  deny: spice run reply 'esc-run' --deny 'perm:$ID'
  deny with message: spice run reply 'esc-run' --deny 'perm:$ID' --message TEXT|-
  $ wait_fake_server

The first escalation resolved and executed; the second is a fresh blocker
with a different permission id.

  $ spice session export esc-run | grep -o '"answer":"allow-exact-for-conversation"'
  "answer":"allow-exact-for-conversation"
  $ spice session export esc-run | grep -c '"type":"tool_claim_finished"'
  1
  $ next_id=$(spice session show --json esc-run | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')
  $ test "$permission_id" != "$next_id" && echo fresh-blocker
  fresh-blocker

Denying the second escalation leaves the command unrun.

  $ cat > escalate-deny.jsonl <<'JSONL'
  > {"expect":{"body_contains":["call-esc-2","denied"]},"response":{"id":"resp-esc-3","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"escalation denied final"}]}]}}
  > JSONL
  $ start_fake_openai escalate-deny.jsonl esc-capture-deny esc-port-deny
  $ spice run reply esc-run --cwd "$PWD" --deny "$next_id" | tail -1
  permission: default
  sandbox: workspace-write (config)
  backend: none refused
  network: restricted
  spice: session saved; resume with: spice resume 'esc-run'
  escalation denied final
  $ wait_fake_server
  $ spice session export esc-run | grep -c '"type":"tool_claim_finished"'
  1
