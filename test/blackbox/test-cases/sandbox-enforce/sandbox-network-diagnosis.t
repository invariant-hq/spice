Under an enforcing workspace-write sandbox the default preset runs a command
without review, but network is restricted. When such a command fails and its
output looks like a blocked network request, the tool result the model receives
explains that the restriction is policy, not a transient error, and names the
recovery paths -- so the model does not retry a blocked request blindly.

  $ unset SPICE_SANDBOX_MODE

  $ cat > net.jsonl <<'JSONL'
  > {"expect":{"body_contains":["net prompt","\"name\":\"shell\""]},"response":{"id":"resp-net-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-n1","call_id":"call-n1","name":"shell","arguments":"{\"command\":\"curl -sS --max-time 5 https://example.com\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-n1"]},"response":{"id":"resp-net-2","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"net final"}]}]}}
  > JSONL
  $ SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT=15 start_fake_openai net.jsonl net-capture net-port
  $ spice run --cwd "$PWD" --json --permission-mode bypass --id net-run "net prompt" | grep -o '"outcome":"completed"'
  spice: session saved; resume with: spice resume 'net-run'
  "outcome":"completed"
  $ wait_fake_server

The tool result carries the diagnosis and its recovery paths.

  $ grep -o 'network access restricted' net-capture/request-2.json
  network access restricted
  $ grep -o 'escalate:true' net-capture/request-2.json
  escalate:true
