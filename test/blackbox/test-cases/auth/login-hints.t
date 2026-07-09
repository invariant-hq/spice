Unknown login methods get a spelling hint from the provider's declared login
methods.

  $ git init -q

  $ spice auth login openai --method browsr
  spice: unknown auth method "browsr" for provider openai
  Hint: did you mean browser?
  [2]

Methods that are not close to any declared method get no hint.

  $ spice auth login openai --method telepathy
  spice: unknown auth method "telepathy" for provider openai
  [2]
