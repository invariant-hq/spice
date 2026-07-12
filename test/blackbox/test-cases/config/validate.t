Spice config validate checks config file syntax and supported field types.

Valid files pass.

  $ spice config validate
  ok

  $ cat > valid.json <<EOF
  > {"model":"openai/gpt-5.5","run":{"max_steps":3}}
  > EOF
  $ spice config validate valid.json
  ok

Unknown fields are allowed by default so editing commands can preserve them,
but strict validation rejects them.

  $ cat > unknown.json <<EOF
  > {"model":"openai/gpt-5.5","extra":true}
  > EOF
  $ spice config validate unknown.json
  ok

  $ spice config validate --strict unknown.json
  spice: unknown.json unknown field: extra
  [1]

  $ cat > unknown-nested.json <<EOF
  > {"run":{"max_steps":3,"extra":true}}
  > EOF
  $ spice config validate --strict unknown-nested.json
  spice: unknown-nested.json run unknown field: extra
  [1]

  $ cat > unknown-provider.json <<EOF
  > {"providers":{"openai":{"base_url":"https://api.example","extra":true}}}
  > EOF
  $ spice config validate --strict unknown-provider.json
  spice: unknown-provider.json providers.openai unknown field: extra
  [1]

  $ cat > unknown-instructions.json <<EOF
  > {"instructions":{"globl":true}}
  > EOF
  $ spice config validate unknown-instructions.json
  ok
  $ spice config validate --strict unknown-instructions.json
  spice: unknown-instructions.json instructions unknown field: globl
  [1]

Explicit paths must exist.

  $ spice config validate missing.json
  spice: missing.json: no such file
  [1]

Malformed JSON fails.

  $ printf 'not json\n' > malformed.json
  $ spice config validate malformed.json
  spice: malformed.json: Expected u while parsing null but found: o
  File "-", line 1, characters 0-2:
  [1]

The JSON root must be an object.

  $ printf '[]\n' > array.json
  $ spice config validate array.json
  spice: array.json config must be a JSON object
  [1]

Supported fields are type checked.

  $ printf '{"model":1}\n' > bad-model.json
  $ spice config validate bad-model.json
  spice: bad-model.json model must be a string
  [1]

  $ printf '{"run":1}\n' > bad-run.json
  $ spice config validate bad-run.json
  spice: bad-run.json run must be an object
  [1]

  $ printf '{"run":{"max_steps":"x"}}\n' > bad-steps.json
  $ spice config validate bad-steps.json
  spice: bad-steps.json run.max_steps must be an integer
  [1]

  $ printf '{"run":{"max_steps":9007199254740992}}\n' > bad-large-steps.json
  $ spice config validate bad-large-steps.json
  spice: bad-large-steps.json run.max_steps must be at most 9007199254740991
  [1]

  $ printf '{"permission":1}\n' > bad-permission-object.json
  $ spice config validate bad-permission-object.json
  spice: bad-permission-object.json permission must be an object
  [1]

  $ printf '{"permission":{"mode":1}}\n' > bad-permission.json
  $ spice config validate bad-permission.json
  spice: bad-permission.json permission.mode is no longer supported; use --permission bypass for one run
  [1]

  $ printf '{"reasoning":"hyper"}\n' > bad-reasoning.json
  $ spice config validate bad-reasoning.json
  spice: bad-reasoning.json reasoning: unknown reasoning effort: hyper
  Hint: expected one of: none, minimal, low, medium, high, xhigh, max
  [1]

  $ printf '{"providers":[]}\n' > bad-providers.json
  $ spice config validate bad-providers.json
  spice: bad-providers.json providers must be an object
  [1]

  $ printf '{"providers":{"openai":1}}\n' > bad-provider.json
  $ spice config validate bad-provider.json
  spice: bad-provider.json providers.openai must be an object
  [1]

  $ printf '{"providers":{"openai":{"base_url":""}}}\n' > bad-provider-url.json
  $ spice config validate bad-provider-url.json
  spice: bad-provider-url.json providers.openai.base_url must not be empty
  [1]

  $ printf '{"instructions":1}\n' > bad-instructions.json
  $ spice config validate bad-instructions.json
  spice: bad-instructions.json instructions must be an object
  [1]

  $ printf '{"instructions":{"project":"no"}}\n' > bad-instructions-bool.json
  $ spice config validate bad-instructions-bool.json
  spice: bad-instructions-bool.json instructions.project must be a boolean
  [1]

  $ printf '{"instructions":{"project_max_bytes":0}}\n' > bad-instructions-budget.json
  $ spice config validate bad-instructions-budget.json
  spice: bad-instructions-budget.json instructions.project_max_bytes must be positive
  [1]

Validation reports every error it finds in one file.

  $ cat > many-errors.json <<EOF
  > {"model":1,"reasoning":"hyper","run":{"max_steps":0,"extra":true},"permission":{"mode":"fast"},"extra":true}
  > EOF
  $ spice config validate --strict many-errors.json
  spice: many-errors.json permission.mode is no longer supported; use --permission bypass for one run
  spice: many-errors.json model must be a string
  spice: many-errors.json reasoning: unknown reasoning effort: hyper
  Hint: expected one of: none, minimal, low, medium, high, xhigh, max
  spice: many-errors.json run.max_steps must be positive
  spice: many-errors.json unknown field: extra
  spice: many-errors.json run unknown field: extra
  [1]
