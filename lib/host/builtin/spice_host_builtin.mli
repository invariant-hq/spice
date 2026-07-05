(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Built-in host provider packages.

    This library bridges Spice's bundled pure provider declarations from
    {!Spice_provider_builtin} to the effectful host adapters that build clients,
    check credentials, refresh OAuth secrets, and revoke secrets, and to the
    interactive login workflows composed from them ({!Login}). *)

(** {1:providers Providers}

    Adapter checks classify provider responses into provider-neutral
    {!Spice_account.Problem} labels: [401]/[403] are [Invalid_credential], [402]
    is [Quota_exceeded], [429] is [Quota_exceeded] when the body mentions quota
    and [Rate_limited] otherwise, [5xx] and transport failures are [Network],
    and unrecognizable responses are the stable [unknown_provider_response]
    label. Successful model-list responses supply the provider-visible model ids
    ([data[].id] for OpenAI and Anthropic, [models[].name] without the [models/]
    prefix for Google). *)

val openai : Spice_host.Host.Provider.t
(** [openai] is the built-in OpenAI host provider package.

    API-key and bearer credentials use the standard OpenAI API. OAuth
    credentials use the ChatGPT backend
    ([https://chatgpt.com/backend-api/codex]): the access token is sent as a
    bearer token and the credential's account id, when present, is sent as the
    [chatgpt-account-id] header. The provider base-URL override applies to
    whichever route the credential selects.

    Checks use [GET {base}/models] on the selected route with the same headers
    as the build. The adapter also refreshes and revokes OAuth secrets through
    OpenAI's token endpoints; both honor the auth endpoint override reported by
    {!Spice_host.Account.provider_auth_base_url}. *)

val anthropic : Spice_host.Host.Provider.t
(** [anthropic] is the built-in Anthropic host provider package.

    API-key and bearer credentials are used directly; OAuth access tokens are
    sent as bearer tokens. Base URL overrides are passed to
    {!Spice_llm_anthropic.Config.make}.

    The adapter checks API-key credentials with [GET {base}/models] and
    [x-api-key], and bearer credentials with the same endpoint and bearer
    authorization. OAuth credentials observe
    {!Spice_account.Problem.Unsupported}. *)

val google : Spice_host.Host.Provider.t
(** [google] is the built-in Google Gemini host provider package.

    Only API-key credentials are accepted; bearer and OAuth credentials error
    with {!Spice_host.Host.Error.Unsupported_credential}. Base URL overrides are
    passed to {!Spice_llm_google.Config.make}.

    The adapter checks API-key credentials with [GET {base}/models?key=...];
    other credential kinds observe {!Spice_account.Problem.Unsupported}. *)

val deepseek : Spice_host.Host.Provider.t
(** [deepseek] is the built-in local DeepSeek host provider package.

    It is credentialless and builds {!Spice_llm_deepseek.client}. Model weights
    are resolved from the local filesystem by the client on first use. Provider
    base URL overrides are rejected because this adapter does not route through
    an HTTP endpoint. *)

val local : Spice_host.Host.Provider.t
(** [local] is the built-in managed local host provider package.

    It is credentialless and builds {!Spice_llm_local.client}, which manages a
    [llama-server] subprocess and downloads curated model weights on demand.
    Downloads of models the machine cannot run are refused by the memory guard.
    Provider base URL overrides are rejected because the adapter owns the server
    endpoint. *)

val ollama : Spice_host.Host.Provider.t
(** [ollama] is the built-in Ollama host provider package.

    It is credentialless and builds {!Spice_llm_ollama.client} against the
    provider base-URL config, defaulting to the daemon's standard
    [http://127.0.0.1:11434]. Model availability is the daemon's runtime answer:
    a request for a model the daemon does not serve fails with the daemon's own
    error. *)

val all : Spice_host.Host.Provider.t list
(** [all] is the built-in host provider package list in deterministic
    registration order: {!openai}, {!anthropic}, {!google}, {!deepseek},
    {!local}, then {!ollama}. *)

val registry : Spice_host.Host.Provider_registry.t
(** [registry] is {!all} validated as a host provider registry. Building a host
    or client performs no provider I/O until the client runs a request. *)

(** {1:web Web tool support} *)

val web_http_client : Eio_unix.Stdenv.base -> Cohttp_eio.Client.t
(** [web_http_client stdenv] is a TLS-capable HTTP client backed by [stdenv]'s
    network capability.

    The client is used by backend-driven web tools such as [web_search].
    Construction installs the Mirage crypto RNG default and reads the platform
    CA authenticator; failures are reported as [Failure] with credential-free
    diagnostics. *)

val web_fetch_https : unit -> Spice_tools.Web_fetch.https
(** [web_fetch_https ()] is the TLS wrapper used by [web_fetch].

    Construction installs the Mirage crypto RNG default and reads the platform
    CA authenticator. The wrapper uses the original URI host for SNI and
    certificate verification; URL validation, DNS policy, and TCP connection
    remain owned by [web_fetch]. *)

(** {1:login Login workflows} *)

module Login = Login
(** Interactive login and logout: method resolution, endpoint rerooting, the
    browser and device-code protocol drives, and the shared persist-then-check
    settling policy. Frontends render {!Login.event}s and {!Login.settled}
    facts and decide when to open a browser. *)
