Provider connections are request resources, not run resources. A long turn must
keep serving model requests when the process descriptor limit is lower than the
number of responses in that turn.

  $ i=1
  $ while [ "$i" -le 49 ]; do
  >   printf '{"response":{"id":"resp-%d","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-%d","call_id":"fd-%d","name":"todo_write","arguments":"{\\"todos\\":[{\\"id\\":\\"fd-probe\\",\\"owner\\":\\"main\\",\\"content\\":\\"Keep serving requests\\",\\"status\\":\\"in_progress\\",\\"priority\\":\\"low\\",\\"position\\":0}]}"}]}}\n' "$i" "$i" "$i" >> responses.jsonl
  >   i=$((i + 1))
  > done
  $ printf '%s\n' '{"response":{"id":"resp-final","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Descriptors stayed bounded."}]}]}}' >> responses.jsonl
  $ start_fake_openai responses.jsonl capture port

The fake server is outside the subshell and retains its normal descriptor
limit. Only Spice runs with the constrained limit, so completing all fifty
responses proves that finished provider connections do not accumulate in the
client process.

  $ (ulimit -n 32; spice run --json --cwd "$PWD" --permission bypass --max-steps 60 --id bounded-fds "keep requesting" 2>&1) | grep -o '"final_text":"Descriptors stayed bounded."'
  "final_text":"Descriptors stayed bounded."
  $ wait_fake_server
  $ find capture -name 'request-*.json' | wc -l | tr -d ' '
  50
