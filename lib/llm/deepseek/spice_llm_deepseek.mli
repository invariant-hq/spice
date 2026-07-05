(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Local DeepSeek provider adapter.

    This library interprets {!Spice_llm.Request.t} values with the local
    DeepSeek V4 GGUF engine. It owns DSML prompt rendering, DSML tool-call
    parsing, model-file resolution, and session reuse. Spice's provider-neutral
    transcript, tool, response, and stream types remain the public boundary.

    Requests are rendered from the full {!Spice_llm.Request.messages} list, so
    prelude messages precede transcript messages. System and developer messages
    become DSML system/developer messages, user messages and tool results must
    be text-only, assistant text and reasoning become DSML assistant content,
    and assistant tool calls become DSML tool calls. Tool declarations are
    attached to the first system/developer message when tool use is automatic;
    if no such message exists, the adapter prepends a default system message
    carrying the declarations. *)

val provider : Spice_llm.Provider.t
(** [provider] is the [deepseek] provider namespace. *)

val api : Spice_llm.Model.Api.t
(** [api] is DeepSeek's DSML chat/tool protocol. *)

val model : string -> Spice_llm.Model.t
(** [model id] is DeepSeek model [id] under {!provider}. *)

module Config : sig
  (** Local DeepSeek inference configuration: model resolution, cache location,
      and decoding parameters. *)

  type t
  (** Local inference configuration.

      [model_dir] defaults to [$XDG_DATA_HOME/ds4], or [$HOME/.local/share/ds4]
      when [XDG_DATA_HOME] is unset. Known model ids and aliases are resolved to
      downloaded GGUF files under this directory. Unknown model ids are treated
      as explicit GGUF filesystem paths.

      [cache_dir] defaults to [$XDG_CACHE_HOME/spice/deepseek], or
      [$HOME/.cache/spice/deepseek] when [XDG_CACHE_HOME] is unset. *)

  val make :
    ?model_dir:string ->
    ?cache_dir:string ->
    ?ctx_size:int ->
    ?max_tokens:int ->
    ?temperature:float ->
    ?top_p:float ->
    ?min_p:float ->
    ?seed:int64 ->
    unit ->
    t
  (** [make ()] is a checked local inference configuration.

      Raises [Invalid_argument] if a supplied path is empty, token limits are
      non-positive, or sampling values are negative or not finite. *)

  val default : t
  (** [default] is [make ()]. *)

  val backend : [ `Metal | `Cuda | `Cpu ]
  (** [backend] is the DeepSeek inference backend selected at link time. *)
end

module Download : sig
  (** Progress reporting for DeepSeek model-artifact downloads. *)

  type phase =
    | Checking
    | Downloading
    | Verifying
    | Installed  (** Download lifecycle phase for a DeepSeek model artifact. *)

  type progress = {
    model : string;  (** DeepSeek model id being resolved. *)
    label : string;  (** Artifact file label suitable for display. *)
    path : string;  (** Local destination path. *)
    received : int64;  (** Bytes transferred so far. *)
    total : int64 option;  (** Total byte count when known. *)
    phase : phase;  (** Current download phase. *)
  }
  (** Progress reported while a known DeepSeek model artifact is installed. *)
end

module Artifact : sig
  (** DeepSeek model-artifact status and installation. *)

  type status =
    | Installed of { path : string }
        (** A known model artifact exists at [path]. *)
    | Missing of { path : string; url : string; size : int64 }
        (** A known model artifact is absent and can be downloaded from [url].
        *)
    | Explicit_path of { path : string; exists : bool }
        (** Unknown model ids are interpreted as explicit GGUF paths. *)

  val status : ?config:Config.t -> string -> (status, string) result
  (** [status id] reports local artifact status for DeepSeek model [id].

      Known model ids and aliases resolve to managed artifacts under {!Config}'s
      model directory. Unknown ids are treated as explicit GGUF paths and are
      never resolved to remote downloads. *)

  val prepare :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    http:Cohttp_eio.Client.t ->
    cancelled:(unit -> bool) ->
    ?observe_download:(Download.progress -> unit) ->
    ?config:Config.t ->
    string ->
    (unit, Spice_llm.Error.t) result
  (** [prepare ~sw ~env ~http ~cancelled id] ensures model [id] is installed.

      For known model ids, missing GGUF artifacts are downloaded with [http],
      verified against their expected size and SHA-256 digest, and then moved
      into the configured model directory. [observe_download], when supplied,
      receives progress updates. Unknown ids are treated as explicit local GGUF
      paths and must already exist. *)
end

val client :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?http:Cohttp_eio.Client.t ->
  ?observe_download:(Download.progress -> unit) ->
  ?config:Config.t ->
  unit ->
  Spice_llm.Client.t
(** [client ~sw ~env ()] is a credentialless local DeepSeek client.

    Model weights are prepared and loaded lazily on the first request for a
    model. A request with [cache_key] reuses a DeepSeek KV-cache session for
    later turns with the same model and cache key. *)
