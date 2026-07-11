(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Managed local model provider.

    This library runs curated open-weight models on the user's machine. It owns
    a manifest of known models (Hugging Face artifact, exact size, SHA-256, and
    memory-guard inputs), the weights download lifecycle, and a managed
    [llama-server] subprocess that interprets requests over the
    OpenAI-compatible chat-completions protocol. Spice's provider-neutral
    transcript, tool, response, and stream types remain the public boundary.

    One server runs at a time: requesting a different model stops the resident
    server and starts a new one, and the server survives across client values so
    weights are not reloaded per turn. The server binary is resolved from [PATH]
    ([brew install llama.cpp]) or {!Config.make}'s [server_binary].

    Known model ids resolve to managed artifacts; unknown ids are treated as
    explicit GGUF filesystem paths, mirroring the DeepSeek provider. *)

val provider : Spice_llm.Provider.t
(** [provider] is the [local] provider namespace. *)

val api : Spice_llm.Model.Api.t
(** [api] is the OpenAI-compatible chat-completions protocol family. *)

val model : string -> Spice_llm.Model.t
(** [model id] is local model [id] under {!provider}. *)

module Config : sig
  (** Managed local-server inference configuration: model and server resolution,
      context window, and startup bounds. *)

  type t
  (** Local inference configuration.

      [model_dir] defaults to [$XDG_DATA_HOME/spice/models], or
      [$HOME/.local/share/spice/models] when [XDG_DATA_HOME] is unset.

      [server_binary] defaults to the [SPICE_LOCAL_SERVER_BINARY] environment
      variable when set, otherwise to resolving [llama-server] from [PATH]. A
      value containing a path separator is used as an explicit path; otherwise
      it is resolved from [PATH].

      [ctx_size] is the context window requested from the server, clamped to the
      model's trained maximum; it defaults to 32768 tokens.

      [startup_timeout_s] bounds server startup including model load; it
      defaults to 300 seconds.

      [memory_budget], when present, overrides the detected memory budget used
      by the download guard and fit verdicts; it exists for tests and for users
      who know better. It defaults to the byte count in the
      [SPICE_LOCAL_MEMORY_BUDGET] environment variable when that is set. *)

  val make :
    ?model_dir:string ->
    ?server_binary:string ->
    ?ctx_size:int ->
    ?startup_timeout_s:float ->
    ?memory_budget:int ->
    unit ->
    t
  (** [make ()] is a checked local inference configuration.

      Raises [Invalid_argument] if a supplied path is empty, [ctx_size] or
      [memory_budget] is non-positive, or [startup_timeout_s] is not positive
      and finite. *)

  val default : t
  (** [default] is [make ()]. *)
end

module Manifest : sig
  (** The curated model catalog: one entry per supported model, carrying the
      artifact facts and the memory-guard inputs.

      Every field is verified against the upstream Hugging Face repository and
      the model's published configuration; sizes and digests are exact. *)

  type entry
  (** One curated local model. *)

  val all : entry list
  (** [all] are the curated models in priority order. *)

  val find : string -> entry option
  (** [find id] is the entry whose {!id} equals [id], if any. *)

  val id : entry -> string
  (** [id e] is the model id used in selectors, e.g. ["qwen3-coder-30b"]. *)

  val display_name : entry -> string
  (** [display_name e] is the human-readable model name. *)

  val family : entry -> string
  (** [family e] is the model family slug for catalog grouping. *)

  val file : entry -> string
  (** [file e] is the GGUF artifact filename. *)

  val url : entry -> string
  (** [url e] is the artifact download URL. *)

  val size : entry -> int64
  (** [size e] is the artifact's exact byte size. *)

  val context_length : entry -> int
  (** [context_length e] is the model's trained context length in tokens. *)

  val reasoning : entry -> bool
  (** [reasoning e] is [true] when the model emits reasoning content and accepts
      a reasoning-effort request field. *)

  val fit : entry -> Spice_modelfit.Model.t
  (** [fit e] is [e]'s memory-guard inputs. For hybrid-attention models the
      layer count is the KV-bearing layer count, not the total. *)
end

module Fit : sig
  (** Fit verdicts for curated models against this machine's memory budget.

      This is the single fit-policy entry point for every surface: the models
      listing, the model picker, and the download guard all judge fit through
      the same estimate. Verdicts are estimates with error bars; they inform
      refusing a multi-gigabyte download, never a hard block on loading. *)

  type t = {
    verdict : Spice_modelfit.Verdict.t;  (** The fit verdict. *)
    need_bytes : int;
        (** Estimated memory need at the decisive context: the judged context
            for [Fits] and [Tight], {!Spice_modelfit.min_useful_context} for
            [Wont_run]. *)
    budget_bytes : int;  (** The machine budget the verdict was judged at. *)
  }

  val find : ?config:Config.t -> string -> t option
  (** [find id] judges model [id] against the machine budget at
      {!Spice_modelfit.default_context}. [id] is a manifest model, or an
      existing explicit [.gguf] path whose guard inputs are read from the file's
      own header. [None] when [id] is neither, the header cannot be parsed, or
      the machine's memory cannot be determined. The budget comes from
      {!Config.make}'s [memory_budget] when set, otherwise from
      {!Spice_modelfit.Machine.detect}. *)

  val to_string : t -> string
  (** [to_string t] is a one-line human summary, e.g.
      ["fits (~14.9 GiB of 24.0 GiB)"], ["fits up to ~49k context"], or
      ["needs ~96.6 GiB, 24.0 GiB usable"]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats {!to_string}[ t]. *)
end

val server_binary : ?config:Config.t -> unit -> (string, string) result
(** [server_binary ()] resolves the inference server binary without running it:
    [Ok path] when {!Config.make}'s [server_binary] (or [llama-server] from
    [PATH]) exists, [Error message] with an installation hint otherwise.
    Diagnostics such as [spice doctor] use this to warn before a request fails.
*)

module Download : sig
  (** Progress reporting for local model-artifact downloads. *)

  type phase =
    | Checking
    | Downloading
    | Verifying
    | Installed  (** Download lifecycle phase for a local model artifact. *)

  type progress = {
    model : string;  (** Local model id being resolved. *)
    label : string;  (** Artifact file label suitable for display. *)
    path : string;  (** Local destination path. *)
    received : int64;  (** Bytes transferred so far. *)
    total : int64 option;  (** Total byte count when known. *)
    phase : phase;  (** Current download phase. *)
  }
  (** Progress reported while a known local model artifact is installed. *)
end

module Artifact : sig
  (** Local model-artifact status, download, and memory-guarded installation. *)

  type status =
    | Installed of { path : string }
        (** A known model artifact exists at [path]. *)
    | Missing of { path : string; url : string; size : int64 }
        (** A known model artifact is absent and can be downloaded from [url].
        *)
    | Explicit_path of { path : string; exists : bool }
        (** Unknown model ids are interpreted as explicit GGUF paths. *)

  val status : ?config:Config.t -> string -> (status, string) result
  (** [status id] reports local artifact status for model [id]. *)

  val prepare :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    http:Cohttp_eio.Client.t ->
    cancelled:(unit -> bool) ->
    ?observe_download:(Download.progress -> unit) ->
    ?config:Config.t ->
    ?force:bool ->
    string ->
    (unit, Spice_llm.Error.t) result
  (** [prepare ~sw ~env ~http ~cancelled id] ensures model [id] is installed.

      Before any bytes move, the download is guarded: when the machine's memory
      budget cannot run the model even at {!Spice_modelfit.min_useful_context},
      [prepare] refuses with an error stating the estimated need and the budget.
      [force] (default [false]) overrides the refusal. The guard is skipped when
      the machine's memory cannot be determined.

      Missing artifacts are downloaded with [http], verified against their exact
      size and SHA-256 digest, and moved into the configured model directory.
      [observe_download], when supplied, receives progress updates. Unknown ids
      are treated as explicit local GGUF paths and must already exist.

      Cancellation returns a {!Spice_llm.Error.Cancelled} error. HTTP, download,
      verification, memory-guard, and missing explicit-path failures return
      provider-boundary errors with diagnostic messages. Interrupted and failed
      downloads remove their private candidates; only a complete verified
      artifact is atomically published at the final path. Abrupt process
      termination may leave an inert private candidate that later installers
      never reuse. *)
end

val client :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?http:Cohttp_eio.Client.t ->
  ?observe_download:(Download.progress -> unit) ->
  ?config:Config.t ->
  unit ->
  Spice_llm.Client.t
(** [client ~sw ~env ()] is a credentialless managed local client.

    The first request for a model prepares its weights (downloading with [http]
    when supplied), starts or reuses the managed server, and streams the
    response. The managed server outlives this client value; it is stopped when
    a different local model is requested or when the process exits. *)
