The Ollama provider is Spice's OpenAI-compatible chat-completions client. It
reaches any server speaking that wire protocol -- Ollama's own /v1 endpoint or a
self-hosted llama.cpp, vLLM, or LM Studio server -- through
providers.ollama.base_url (here SPICE_OLLAMA_BASE_URL). The daemon owns the
model set, so an arbitrary model id resolves without a built-in catalog entry,
and authentication is optional.

A bare daemon needs no credential: the configured model id rides the request and
the streamed reply is returned.

  $ start_fake_ollama "hello from the lab llama" capture-bare
  $ spice run --cwd "$PWD" --id ollama-bare "say hi"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  hello from the lab llama
  spice: session saved; resume with: spice resume 'ollama-bare'
  $ wait_fake_server

The streamed reply above is proof the request reached the chat-completions
endpoint (other paths answer 404). The captured request body carries the
arbitrary model id from config, and a bare daemon receives no authorization
header.

  $ grep -o '"model":"my-llama-model"' capture-bare/request-1.json
  "model":"my-llama-model"
  $ grep authorization capture-bare/request-1.headers
  [1]

A key-protected deployment takes an API key from the OLLAMA_API_KEY environment
variable, sent as a bearer authorization header on every request.

  $ start_fake_ollama "keyed reply ok" capture-env
  $ OLLAMA_API_KEY=lab-secret spice run --cwd "$PWD" --id ollama-env "say hi"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  keyed reply ok
  spice: session saved; resume with: spice resume 'ollama-env'
  $ wait_fake_server
  $ grep -o 'authorization: Bearer lab-secret' capture-env/request-1.headers
  authorization: Bearer lab-secret

A stored credential works the same way: log the key into the auth store once,
then runs carry it without the environment variable.

  $ printf 'stored-lab-key' | spice auth login ollama --api-key-stdin > /dev/null
  $ start_fake_ollama "stored reply ok" capture-store
  $ spice run --cwd "$PWD" --id ollama-store "say hi"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  stored reply ok
  spice: session saved; resume with: spice resume 'ollama-store'
  $ wait_fake_server
  $ grep -o 'authorization: Bearer stored-lab-key' capture-store/request-1.headers
  authorization: Bearer stored-lab-key

Pointing the openai provider at such a server is the wrong tool: it speaks the
OpenAI Responses API, and its model id is validated against the built-in openai
catalog. An arbitrary model id under a custom openai base URL is rejected with a
diagnostic that redirects to the ollama provider.

  $ OPENAI_API_KEY=sk-test SPICE_MODEL=openai/my-llama-model SPICE_OPENAI_BASE_URL=http://127.0.0.1:8080/v1 spice run --cwd "$PWD" "hi"
  permission: default
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: model names unknown model "my-llama-model" for provider "openai"
  Hint: providers.openai.base_url is set to http://127.0.0.1:8080/v1, but the model id is still validated against the built-in openai catalog
  Hint: for a self-hosted OpenAI-compatible server (llama.cpp, vLLM, LM Studio), use the ollama provider: set providers.ollama.base_url and model ollama/<id>
  Hint: run `spice config unset model` to clear it
  [1]

Without a base-URL override, an unknown openai model keeps the ordinary
catalog-typo hints (no ollama redirect).

  $ OPENAI_API_KEY=sk-test SPICE_MODEL=openai/gpt-5.5-typo spice run --cwd "$PWD" "hi" 2>&1 | grep -c "use the ollama provider"
  0
  [1]
