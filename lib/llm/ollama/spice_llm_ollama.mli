(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Ollama provider adapter.

    This library interprets {!Spice_llm.Request.t} values against a running
    Ollama daemon over its OpenAI-compatible chat-completions endpoint. The
    daemon owns the model set: Spice declares no static Ollama models, ids are
    whatever the daemon serves (e.g. ["qwen3-coder:30b"]), and pulling models is
    the user's `ollama pull`, not Spice's concern. Spice's provider-neutral
    transcript, tool, response, and stream types remain the public boundary.

    The client connects to {!Config.make}'s [base_url] ([http://127.0.0.1:11434]
    by default; override it for a daemon on another machine via the provider
    base-URL config). Authentication is optional: a bare daemon needs none, a
    key-protected one takes a {!Credential.t} sent as a bearer authorization
    header. A request for a model the daemon does not have fails at request time
    with the daemon's own error. *)

val provider : Spice_llm.Provider.t
(** [provider] is the [ollama] provider namespace. *)

val api : Spice_llm.Model.Api.t
(** [api] is the OpenAI-compatible chat-completions protocol family. *)

val model : string -> Spice_llm.Model.t
(** [model id] is Ollama model [id] under {!provider}. *)

module Config : sig
  type t
  (** Connection configuration.

      [base_url] is the daemon's root URL and defaults to
      [http://127.0.0.1:11434]; the OpenAI-compatible endpoint lives under its
      [/v1] path and the native discovery API under [/api]. *)

  val make : ?base_url:string -> ?timeout_s:float -> unit -> t
  (** [make ()] is a checked connection configuration.

      [timeout_s] is the whole logical-request deadline, covering connection
      setup and streamed response consumption. It defaults to 1800 seconds.

      Raises [Invalid_argument] if [base_url] is empty or contains a newline, or
      [timeout_s] is not positive and finite. *)

  val default : t
  (** [default] is [make ()]. *)

  val base_url : t -> string
  (** [base_url t] is [t]'s normalized daemon root URL. *)

  val timeout_s : t -> float
  (** [timeout_s t] is the whole logical-request deadline in seconds. *)
end

module Credential : sig
  type t
  (** Authentication material for a key-protected daemon.

      Credential values are inert; the client sends them as a bearer
      authorization header on every request. *)

  val api_key : string -> t
  (** [api_key key] is API-key material.

      Raises [Invalid_argument] if [key] is empty or contains a newline. *)

  val bearer : string -> t
  (** [bearer token] is bearer-token material.

      Raises [Invalid_argument] if [token] is empty or contains a newline. *)
end

val client :
  env:Eio_unix.Stdenv.base ->
  ?config:Config.t ->
  ?credential:Credential.t ->
  unit ->
  Spice_llm.Client.t
(** [client ~env ()] is an Ollama client streaming over the daemon's
    chat-completions endpoint. Without [credential] requests carry no
    authorization header — the bare local-daemon default. Each response closes
    its daemon connection before returning. *)
