Escalation drops the filesystem confinement, not the credential strip. An
approved escalated command runs unconfined, but its environment is still
filtered by the same policy the confined path uses: credential- and
loader-shaped variables are removed, benign variables pass through. Only
danger-full-access passes the environment verbatim.

  $ export SPICE_SANDBOX_MODE=workspace-write
  $ export SPICE_SANDBOX_REQUIRE=off
  $ export _SPICE_TEST_SANDBOX_UNAVAILABLE=1
  $ export SPICE_TRUSTED_WORKSPACE="$PWD"

A credential-shaped variable and a benign one, both present in the parent
environment the escalated command inherits from.

  $ export MYSERVICE_API_KEY=sk-leak-canary-42
  $ export MYSERVICE_REGION=eu-west

The model escalates a command that echoes both variables, defaulting to a
marker when a variable is absent from the child environment.

  $ cat > env-start.jsonl <<'JSONL'
  > {"expect":{"body_contains":["env prompt","\"name\":\"shell\""]},"response":{"id":"resp-env-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-env-1","call_id":"call-env-1","name":"shell","arguments":"{\"command\":\"printf 'akey[%s] region[%s]' \\\"${MYSERVICE_API_KEY:-STRIPPED}\\\" \\\"${MYSERVICE_REGION:-NONE}\\\"\",\"escalate\":true,\"description\":\"sandbox blocked the previous attempt\"}"}]}}
  > JSONL
  $ start_fake_openai env-start.jsonl env-capture-start env-port-start
  $ spice run --cwd "$PWD" --id env-run "env prompt" >env-block.out 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server
  $ permission_id=$(spice session show --json env-run | sed -n 's/.*"permission_id":"\([^"]*\)".*/\1/p')

Approving executes the command unconfined. The output fed back to the
provider must show the credential variable stripped (the [STRIPPED] default)
and the benign variable preserved, and must never carry the secret value.

  $ cat > env-next.jsonl <<'JSONL'
  > {"expect":{"body_contains":["akey[STRIPPED]","region[eu-west]"],"body_not_contains":["sk-leak-canary-42"]},"response":{"id":"resp-env-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"env checked"}]}]}}
  > JSONL
  $ start_fake_openai env-next.jsonl env-capture-next env-port-next
  $ spice run reply env-run --cwd "$PWD" --allow-session "$permission_id" >env-next.out 2>&1; echo exit:$?
  exit:0
  $ wait_fake_server

The escalated command ran and the run completed on the final message.

  $ spice session export env-run | grep -c '"type":"tool_claim_finished"'
  1
  $ grep -c 'env checked' env-next.out
  1
