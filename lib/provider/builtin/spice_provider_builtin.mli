(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Built-in provider catalog.

    This library exports Spice's bundled {!Spice_provider.t} declarations for
    hosted model providers. Each declaration combines a provider namespace,
    display metadata, auth declarations, model metadata, and a default model.

    The catalog is static data. It does not read config or environment
    variables, inspect accounts, refresh credentials, construct clients, run
    login flows, evaluate host policy, or contact provider APIs. Hosts compose
    these values into a {!Spice_provider.Catalog.t} or a
    {!Spice_host.Provider_registry.t} before lookup.

    Built-in model metadata follows the invariants enforced by
    {!Spice_provider.make} and {!Spice_provider.Model.make}: model namespaces
    match their provider, provider-local model ids are unique within a provider,
    list metadata is duplicate-free and deterministic, and default models are
    declared in their provider's model list and selectable.

    Runtime availability is outside this module. Credentials, base URLs, account
    state, config enablement, and permission policy are host facts. A built-in
    model may still be statically [Deprecated] or [Unavailable _]; callers that
    list or select models should use {!Spice_provider.Model.visible},
    {!Spice_provider.Model.selectable}, and {!Spice_provider.Catalog} according
    to their UI contract.

    These values expose no recoverable result errors. Invalid built-in metadata
    is a programmer error in this library and is rejected by the underlying
    provider constructors. *)

val openai : Spice_provider.t
(** [openai] is the built-in OpenAI provider declaration.

    Its provider id is [openai]. Model identities are OpenAI request identities
    from {!Spice_llm_openai}, and the declared default model is [gpt-5.5]. Auth
    declares [OPENAI_API_KEY] plus browser, ChatGPT device-code, and API-key
    login methods.

    The declaration is static catalog metadata. OAuth endpoints and login
    methods are declarations for a host to interpret; evaluating them is not an
    effect performed by this value. Some known OpenAI aliases may be declared
    but marked unavailable when Spice cannot route them through the supported
    OpenAI API surface. *)

val anthropic : Spice_provider.t
(** [anthropic] is the built-in Anthropic provider declaration.

    Its provider id is [anthropic]. Model identities are Anthropic request
    identities from {!Spice_llm_anthropic}, and the declared default model is
    [claude-sonnet-5]. Auth declares [ANTHROPIC_API_KEY] and an API-key login
    method. *)

val google : Spice_provider.t
(** [google] is the built-in Google Gemini provider declaration.

    Its provider id is [google]. Model identities are Google request identities
    from {!Spice_llm_google}, and the declared default model is
    [gemini-3.5-flash]. Auth declares [GOOGLE_API_KEY],
    [GOOGLE_GENERATIVE_AI_API_KEY], [GEMINI_API_KEY], and an API-key login
    method. *)

val deepseek : Spice_provider.t
(** [deepseek] is the built-in local DeepSeek provider declaration.

    Its provider id is [deepseek]. Model identities are local DeepSeek DSML
    request identities from {!Spice_llm_deepseek}, and the declared default
    model is [q2-q4-imatrix]. Auth is {!Spice_provider.Auth.none}. Undeclared
    provider-local ids ending in [.gguf] resolve through the dynamic-model
    policy as explicit local weight files; other undeclared ids stay unknown.
    File existence and loadability are host/runtime concerns. *)

val local : Spice_provider.t
(** [local] is the built-in managed local provider declaration.

    Its provider id is [local]. Model identities are chat-completions request
    identities from {!Spice_llm_local}, the model list derives from the curated
    {!Spice_llm_local.Manifest}, and the declared default model is
    [qwen3-coder-30b]. Auth is {!Spice_provider.Auth.none}. Declared model
    weights are downloaded and served by the host adapter's managed server.
    Undeclared provider-local ids ending in [.gguf] resolve through the
    dynamic-model policy as explicit local weight files; other undeclared ids
    stay unknown. File existence and loadability are host/runtime concerns. *)

val ollama : Spice_provider.t
(** [ollama] is the built-in Ollama provider declaration.

    Its provider id is [ollama]. The declaration lists no static models: the
    daemon owns the model set, so every id resolves through the declared
    dynamic-model policy and is interpreted by the daemon at request time. Auth
    is optional: [OLLAMA_API_KEY] and API-key login are declared, but local
    unauthenticated daemons remain valid. The daemon endpoint defaults to
    [http://127.0.0.1:11434] and follows the provider base-URL config. *)

val all : Spice_provider.t list
(** [all] is the built-in provider declaration list in deterministic
    registration order: {!openai}, {!anthropic}, {!google}, {!deepseek},
    {!local}, then {!ollama}.

    This list is the intended composition entry point for hosts that want
    Spice's default provider set. The provider values are immutable and
    independent; callers may prepend, append, filter, or replace declarations
    before validating the final provider set as a {!Spice_provider.Catalog.t} or
    a {!Spice_host.Provider_registry.t}. *)

val catalog : Spice_provider.Catalog.t
(** [catalog] is {!all} validated as a pure provider/model catalog.

    Prefer this value for built-in-only provider and model lookup. Hosts that
    compose built-ins with additional declarations should build their own
    catalog from the final provider list. *)
