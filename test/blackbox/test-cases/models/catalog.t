The model catalog is available without provider network calls.

  $ spice models --json | sed -E 's/^\{"schema_version":([0-9]+),"type":"models","models":\[.*/schema_version=\1 type=models/'
  schema_version=1 type=models

  $ spice models --json | grep -o '"selector":"openai/gpt-5.5"' | head -n 1
  "selector":"openai/gpt-5.5"

  $ spice models --json | grep -o '"selector":"anthropic/claude-sonnet-4-6"' | head -n 1
  "selector":"anthropic/claude-sonnet-4-6"

Provider filtering is explicit.

  $ spice models --provider openai | sed -n '1p'
  MODEL                 STATUS  CONTEXT  COST $/MTOK  FIT

  $ spice models --provider openai | grep '^openai/gpt-5.5 '
  openai/gpt-5.5 *      stable  1050000  5/30         -

Hidden models stay out of default listings and appear with --all.

  $ spice models --provider openai | grep chat-latest
  [1]
  $ spice models --all --provider openai | grep -c chat-latest
  1

Unknown providers are usage errors and leave stdout empty.

  $ spice models --provider nope >stdout 2>stderr; code=$?; cat stdout; cat stderr; echo "code=$code"
  spice: unknown provider "nope"
  code=2

Model details expose catalog metadata for a selector.

  $ spice models show openai/gpt-5.5 --json | grep -o '"selector":"openai/gpt-5.5"'
  "selector":"openai/gpt-5.5"

  $ spice models show openai/gpt-5.5 --json | grep -o '"provider_default":true'
  "provider_default":true

  $ spice models show openai/gpt-5.5 --json | grep -o '"capabilities":\["apply-patch","json_schema","reasoning","tools"\]'
  "capabilities":["apply-patch","json_schema","reasoning","tools"]

  $ spice models show openai/gpt-5.5 --json | grep -o '"input_per_million":5'
  "input_per_million":5

The current command resolves the configured main and small models.

  $ spice models current --json | grep -o '"type":"models_current"'
  "type":"models_current"

  $ spice models current
  ROLE   MODEL                SOURCE            CREDENTIALS
  model  openai/gpt-5.5       provider default  missing
  small  openai/gpt-5.4-nano  small heuristic   missing

Selecting a model writes the canonical selector.

  $ spice models select openai/gpt-5.5 --project-local
  $ spice config get --project-local model
  openai/gpt-5.5

Non-selectable models are rejected before any file mutation.

  $ spice models select openai/gpt-5-chat-latest --project-local
  spice: unavailable model "openai/gpt-5-chat-latest": OpenAI Responses does not support this chat alias
  Hint: run `spice models --all` to inspect model status
  [2]
  $ spice config get --project-local model
  openai/gpt-5.5

Bare model ids fail with canonical-selector hints.

  $ spice models show gpt-5.5
  spice: invalid model "gpt-5.5": model selector must be in the form provider/model
  Hint: did you mean openai/gpt-5.5?
  [2]
