(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Google Gemini provider for [spice.llm].

    This library translates checked {!Spice_llm.Request.t} values to the Gemini
    [streamGenerateContent] protocol and translates streamed Gemini chunks back
    to semantic {!Spice_llm.Stream.t} values.

    The usual construction path is {!model}, {!Credential.api_key}, optional
    {!Config.make}, then {!client}. Run requests through
    {!Spice_llm.Client.stream} for live events or {!Spice_llm.Client.response}
    for a collected response.

    Credentials, endpoint overrides, and HTTP policy are supplied explicitly.
    The library does not read process environment variables, choose CLI
    precedence, persist sessions, discover accounts, price models, execute
    tools, or own UI model selection.

    Request translation follows Gemini's wire format:

    - system and developer messages from the prelude and transcript become
      [systemInstruction.parts] in provider order;
    - user text becomes [text], and user base64 media becomes [inlineData];
    - assistant text, reasoning, and tool calls become model [parts];
    - tool results become user [functionResponse] parts with text content joined
      by newlines;
    - tools become Gemini [functionDeclarations], with JSON schemas projected to
      Gemini's supported schema shape.

    Unsupported request features are reported as structured {!Spice_llm.Error.t}
    values rather than being silently degraded. *)

(** {1:configuration Configuration} *)

module Config = Config
(** Google Gemini client configuration. *)

module Credential : sig
  type t
  (** The type for Google Gemini credentials.

      Credential values are inert and are only turned into authorization headers
      when {!client} starts a request. *)

  val api_key : string -> t
  (** [api_key key] is a Google Generative AI API key sent as [x-goog-api-key].

      Raises [Invalid_argument] if [key] is empty or contains a newline. *)
end

(** {1:identity Provider identity} *)

val provider : Spice_llm.Provider.t
(** [provider] is the [google] provider namespace. *)

val api : Spice_llm.Model.Api.t
(** [api] is the [gemini] model API family. *)

val model : string -> Spice_llm.Model.t
(** [model id] is Google Gemini model [id].

    Raises [Invalid_argument] if [id] is empty. *)

(** {1:clients Clients} *)

val client :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?config:Config.t ->
  credential:Credential.t ->
  unit ->
  Spice_llm.Client.t
(** [client ~sw ~env ~credential ()] is a Google Gemini client.

    The returned client accepts requests whose model has {!provider} and {!api}.
    Other models are rejected by {!Spice_llm.Client.stream} before the Google
    adapter starts transport work.

    The client borrows [sw] and [env] for HTTP calls, TLS, retries, timeouts,
    and stream reads. Request startup failures are returned by
    {!Spice_llm.Client.stream}; failures after a stream is returned are emitted
    by the stream as {!Spice_llm.Stream.Failed}. Cancellation observed before
    startup returns an error with kind {!Spice_llm.Error.Cancelled};
    cancellation observed while reading closes the raw stream and emits
    {!Spice_llm.Stream.Failed}.

    Startup errors include unsupported provider features such as replay,
    JSON-schema response format, URI media, tool-result media, and reasoning
    parts without text or summary. Gemini non-2xx responses are classified by
    HTTP status and, when present, Google error [status]; response bodies are
    redacted before being attached to {!Spice_llm.Error.t}.

    Stream events include non-empty text deltas, reasoning-summary deltas for
    Gemini [thought] parts, complete tool calls with synthesized [tool_N] ids,
    and usage snapshots. Missing function-call names and malformed streamed JSON
    are stream-phase decode failures. Raw SSE EOF completes the stream with the
    accumulated response, including an empty response when Gemini sends a
    terminal candidate without parts. *)
