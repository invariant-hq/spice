(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OpenAI Responses provider for [spice.llm].

    This library translates checked {!Spice_llm.Request.t} values to the OpenAI
    Responses protocol and translates OpenAI responses back to semantic
    {!Spice_llm.Stream.t} values.

    The usual construction path is {!model}, one of the {!Credential}
    constructors, optional {!Config.make}, then {!client}. Run requests through
    {!Spice_llm.Client.stream} for live events or {!Spice_llm.Client.response}
    for a collected response.

    Credentials, endpoint overrides, and HTTP policy are supplied explicitly.
    The library does not read process environment variables, choose CLI
    precedence, persist sessions, discover accounts, price models, execute
    tools, or own UI model selection.

    Unsupported request features are reported as structured {!Spice_llm.Error.t}
    values rather than being silently degraded. *)

(** {1:configuration Configuration} *)

module Config = Config
(** OpenAI client configuration. *)

module Credential : sig
  type t
  (** The type for OpenAI credentials.

      Credential values are inert and are only turned into authorization headers
      when {!client} starts a request. *)

  val api_key : string -> t
  (** [api_key key] is an OpenAI API-key credential.

      The key is sent as bearer authorization. Raises [Invalid_argument] if
      [key] is empty or contains a newline. *)

  val bearer : string -> t
  (** [bearer token] is a bearer-token credential.

      Raises [Invalid_argument] if [token] is empty or contains a newline. *)
end

(** {1:identity Provider identity} *)

val provider : Spice_llm.Provider.t
(** [provider] is the OpenAI provider namespace. *)

val api : Spice_llm.Model.Api.t
(** [api] is the OpenAI Responses API family. *)

val model : string -> Spice_llm.Model.t
(** [model id] is OpenAI Responses model [id].

    Raises [Invalid_argument] if [id] is empty. *)

(** {1:projection Provider projection}

    Prelude messages are sent before transcript messages. Prelude system and
    developer messages become the OpenAI top-level [instructions] string.
    Prelude user messages and all transcript messages remain in [input] in
    provider order. User text becomes [input_text], and user media must be
    images and becomes [input_image] with a URI or
    [data:{media_type};base64,{data}] URL.

    Assistant text becomes [output_text], assistant tool calls become
    [function_call], and provider-owned reasoning becomes [reasoning] items with
    encrypted content, plus summary text and reasoning text when present.
    Retained OpenAI item ids are not replayed because requests use
    [store=false], and reasoning without encrypted content is omitted because it
    cannot carry stateless continuation state. Tool results become
    [function_call_output]; empty results encode as an empty string, text-only
    results are joined with newlines, and image/text results encode as
    structured content. Non-image media is unsupported.

    Tool declarations become OpenAI function tools. [Auto], [No_tools],
    [Required], and [Tool name] map to [tool_choice] values [auto], [none],
    [required], and the named function choice. JSON-schema response format maps
    to [text.format]. Requested reasoning effort maps to [reasoning.effort];
    [Max] is not supported. When reasoning is requested, the adapter includes
    [reasoning.encrypted_content] and omits [temperature].

    Every request sends the full prelude and transcript. Only prelude
    system/developer messages are hoisted to [instructions], keeping that prefix
    byte-stable across a session. The tokenized prefix is therefore append-only
    across requests, which is what makes OpenAI prompt caching effective
    together with the request's [prompt_cache_key]. *)

(** {1:clients Clients} *)

val client :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?config:Config.t ->
  credential:Credential.t ->
  unit ->
  Spice_llm.Client.t
(** [client ~sw ~env ~credential ()] is an OpenAI Responses client.

    The returned client accepts requests whose model has {!provider} and {!api}.
    Other models are rejected by {!Spice_llm.Client.stream} before the OpenAI
    adapter starts transport.

    The client borrows [sw] and [env] for HTTP calls, TLS, retries, timeouts,
    and stream reads. Request startup failures are returned by
    {!Spice_llm.Client.stream}; failures after a stream is returned are emitted
    by the stream as {!Spice_llm.Stream.Failed}. Cancellation observed before
    startup returns an error with kind {!Spice_llm.Error.Cancelled};
    cancellation observed while reading closes the raw stream and emits
    {!Spice_llm.Stream.Failed}.

    Startup errors include unsupported request features, cancellation observed
    before transport, unsupported model APIs, non-2xx HTTP responses after
    retries, transport failures, timeouts, and local JSON encoding failures.
    HTTP status codes and OpenAI error codes are classified into
    provider-neutral {!Spice_llm.Error.kind} values; raw response bodies are
    redacted before being attached to {!Spice_llm.Error.t}.

    Stream events expose non-empty text deltas, reasoning-summary deltas,
    partial tool-input deltas, completed tool calls, and usage snapshots. The
    terminal response is produced on [response.completed] or
    [response.incomplete] and contains the durable assistant message, provider
    response id/model, normalized stop reason, provider stop label, usage, and
    retained reasoning parts. Malformed SSE JSON, malformed tool-call input,
    provider [response.failed] or [error] events, terminal events without
    [response], EOF before a terminal event, cancellation during streaming, and
    streams with no assistant parts are emitted as stream-phase failures. *)
