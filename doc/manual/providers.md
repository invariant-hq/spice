# Providers and accounts

Spice separates three choices that other clients often combine:

1. a provider declaration says which models, authentication methods, and wire
   protocol exist;
2. an account resolves a credential for that provider;
3. a model selector chooses the model used by a turn.

Changing a model does not change credentials, and logging in does not silently
rewrite the selected model.

## Quick setup

Use the provider's default login method, inspect readiness, then choose a
model:

```sh
spice auth login anthropic
spice auth status anthropic --refresh
spice models --provider anthropic
spice models select anthropic/MODEL
```

`spice auth login` prompts for API keys with terminal echo disabled. For a
script, read the key from standard input instead of putting it in an argument:

```sh
printenv OPENAI_API_KEY | spice auth save openai --api-key-stdin
```

The TUI exposes the same workflows through `/login`, `/logout`, and `/model`.

## Built-in providers

| Provider | Authentication | Model source |
| --- | --- | --- |
| `openai` | Browser OAuth, ChatGPT device code, API key, or `OPENAI_API_KEY` | Built-in OpenAI catalog; uses the Responses API. |
| `anthropic` | API key or `ANTHROPIC_API_KEY` | Built-in Anthropic catalog. |
| `google` | API key, `GOOGLE_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, or `GEMINI_API_KEY` | Built-in Gemini catalog. |
| `deepseek` | None | Built-in local models or an explicit `.gguf` model path. |
| `local` | None | Managed local models or an explicit `.gguf` model path. |
| `ollama` | Optional API key or `OLLAMA_API_KEY` | Dynamic: the configured daemon owns its model ids. |

Run `spice models --all` for the current catalog and static availability.
Provider defaults and model metadata change with the catalog, so the command
output—not a copied list in this manual—is authoritative.

## Login methods and storage

OpenAI declares three login method ids:

```sh
spice auth login openai --method browser
spice auth login openai --method device-code
spice auth login openai --method api-key
```

Anthropic and Google currently declare `api-key`. Omitting `--method` lets the
provider choose its default interactive method. Without a terminal, select an
explicit non-interactive method; API-key input additionally needs
`--api-key-stdin`.

Stored credentials live in `$SPICE_CONFIG_HOME/auth.json` when the explicit
config-home override is set. Otherwise the path is
`$XDG_CONFIG_HOME/spice/auth.json` or `~/.config/spice/auth.json`. Spice creates
and atomically replaces the file with mode `0600`; `auth status` warns when an
existing file has broader permissions. Do not commit or hand-author this file.

Credentials may be named within one provider:

```sh
printenv WORK_OPENAI_API_KEY | \
  spice auth save openai --name work --api-key-stdin
spice auth status openai --name work
spice auth remove openai --name work
```

The name selects a stored fallback; it does not override an active environment
credential.

## Credential precedence

Resolution is deterministic. A host-supplied process credential wins first,
then the provider's non-empty environment variables, then the selected stored
credential. For ordinary CLI use this means environment before store.

An empty environment variable is ignored. `--name NAME` changes only which
stored credential is considered; a non-empty environment credential still
wins. `auth status` reports the winning source and a short safe fingerprint,
never the credential value.

Removing or logging out affects the store only. If an environment credential
is active, Spice reports that it remains active and cannot be removed from the
calling process.

## Readiness and refresh

`spice auth status [PROVIDER]` is passive: it reads declarations, environment,
and the local store without contacting a provider. Its phases are:

| Phase | Meaning |
| --- | --- |
| `missing` | No credential resolved for the provider route. |
| `unchecked` | A credential resolved but has not been validated in this command. |
| `ready` | The provider check completed without an account problem. |
| `degraded` | The route was checked and has a non-fatal problem. |
| `blocked` | The route was checked and requires user action before a run can succeed. |

Use `--refresh` when you want provider I/O and a current readiness check:

```sh
spice auth status openai --refresh
spice auth status --json
```

Checked readiness is ephemeral; Spice does not persist a claim that a
credential remains valid. OAuth access tokens may be refreshed when needed,
but secret material never enters account status, diagnostics, or session
events.

`spice auth logout PROVIDER --revoke` attempts provider revocation for a stored
OAuth credential before removing it locally. A revocation failure produces a
warning but does not strand the local credential. API keys cannot be revoked
through Spice and are removed locally.

## Selecting models

Model selectors use `provider/model`:

```sh
spice models                         # visible catalog
spice models show provider/model     # capabilities and metadata
spice models current                 # effective main and small choices
spice models select provider/model
spice models select provider/model --small
```

`models current` also explains where each choice came from. `models select`
writes user configuration by default; `--project` and `--project-local` use the
same config layers described in [Configuration](configuration.md). A one-run
override uses `--model provider/model` or `SPICE_MODEL`.

Managed local models expose `spice models download MODEL` to fetch weights
before first use. The catalog's `FIT` column is an estimate, not an allocation
guarantee.

## OpenAI-compatible servers

Use the `ollama` provider for servers implementing the OpenAI
**chat-completions** endpoint (`POST /v1/chat/completions`), including Ollama,
llama.cpp, vLLM, and LM Studio. Configure the server root; Spice appends the
endpoint path:

```sh
spice config set providers.ollama.base_url http://127.0.0.1:8080
spice config set model ollama/your-model-id
```

or for one shell:

```sh
export SPICE_OLLAMA_BASE_URL=http://127.0.0.1:8080
export SPICE_MODEL=ollama/your-model-id
```

The daemon owns the model set, so any non-empty `ollama/MODEL` id is routed to
it; Spice does not call `GET /v1/models`. A local daemon needs no credential.
For a protected deployment, set `OLLAMA_API_KEY` or save an Ollama API key.

Do not point `providers.openai.base_url` at a chat-completions-only server. The
`openai` provider uses the OpenAI **Responses** endpoint (`POST /v1/responses`)
and validates model ids against its built-in catalog; it is a different wire
contract despite the similar name.
