(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Memory-fit estimates for local model weights.

    This module answers one question before any bytes are downloaded or loaded:
    can this machine run this model, and at what context length? Callers
    describe a model's guard inputs with {!Model.make} (from a curated manifest)
    or {!Gguf.model} (from the header of a GGUF file), obtain the machine's
    memory budget with {!Machine.budget}, and ask for an {!estimate} or a
    {!verdict}.

    Estimates follow the standard decomposition for llama.cpp-family engines:
    weights (the quantized file size) plus KV cache
    ([2 x layers x kv_heads x head_dim x context] elements) plus a fixed
    allowance for the compute graph and engine overhead. The KV term assumes
    grouped-query or multi-head attention; architectures with compressed KV
    (multi-head latent attention) are overestimated, which errs toward caution.
    Numbers are estimates with real error bars: refusing a download on
    {!Verdict.Wont_run} is sound, but a load should never be hard-blocked on
    {!Verdict.Tight}.

    Everything is pure except {!Machine.detect}. *)

(** {1:machine Machine budget} *)

module Machine : sig
  (** The memory a machine can devote to model weights and KV cache. *)

  type os = Macos | Linux | Other  (** Operating system family. *)

  type t
  (** Machine memory facts relevant to model fit. *)

  val make : os:os -> ram_bytes:int -> ?wired_limit_bytes:int -> unit -> t
  (** [make ~os ~ram_bytes ?wired_limit_bytes ()] is a machine with [ram_bytes]
      of physical memory. [wired_limit_bytes] is macOS's [iogpu.wired_limit_mb]
      sysctl converted to bytes, when the user raised it from its default; it
      overrides the default budget heuristic.

      Raises [Invalid_argument] if [ram_bytes] is not positive or
      [wired_limit_bytes] is present and not positive. *)

  val detect : unit -> t option
  (** [detect ()] probes the running machine: on macOS the [hw.memsize] and
      [iogpu.wired_limit_mb] sysctls, on Linux [/proc/meminfo]. [None] when
      physical memory cannot be determined; callers should then skip the guard
      rather than refuse everything. *)

  val os : t -> os
  (** [os t] is [t]'s operating system family. *)

  val ram_bytes : t -> int
  (** [ram_bytes t] is [t]'s physical memory in bytes. *)

  val budget : t -> int
  (** [budget t] is the bytes available for weights plus KV cache. On macOS this
      is the wired limit when {!make} was given one, otherwise 75% of physical
      memory — Metal's default working-set cap. On other systems it is 75% of
      physical memory, a conservative share that leaves room for the OS and the
      agent itself; GPU VRAM accounting is out of scope. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:model Model guard inputs} *)

module Model : sig
  (** The facts about a quantized model that determine its memory need. *)

  type t
  (** Guard inputs for one quantized build of a model. *)

  val make :
    weights_bytes:int ->
    n_layers:int ->
    n_kv_heads:int ->
    head_dim:int ->
    max_context:int ->
    t
  (** [make] describes one quantized model file. [weights_bytes] is the file's
      exact size — quantization is already priced into it. [n_kv_heads] is the
      grouped-query head count (equal to the attention head count for multi-head
      attention). [max_context] is the model's trained context length in tokens.

      Raises [Invalid_argument] if any field is not positive. *)

  val weights_bytes : t -> int
  (** [weights_bytes t] is the model file size in bytes. *)

  val n_layers : t -> int
  (** [n_layers t] is the transformer block count. *)

  val n_kv_heads : t -> int
  (** [n_kv_heads t] is the KV head count. *)

  val head_dim : t -> int
  (** [head_dim t] is the per-head dimension. *)

  val max_context : t -> int
  (** [max_context t] is the trained context length in tokens. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:estimates Estimates} *)

type kv_dtype =
  | F16
  | Q8_0
  | Q4_0
      (** Element type of the KV cache. [F16] is the llama.cpp default; the
          quantized types match its [q8_0] and [q4_0] cache options, block
          overhead included. *)

module Estimate : sig
  (** A memory-need estimate, decomposed so interfaces can show the parts. *)

  type t = {
    weights_bytes : int;  (** The quantized weights file. *)
    kv_cache_bytes : int;  (** KV cache at the requested context. *)
    overhead_bytes : int;  (** Compute graph, engine, and safety margin. *)
  }

  val total_bytes : t -> int
  (** [total_bytes t] is the sum of [t]'s parts. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

val estimate : ?kv_dtype:kv_dtype -> context:int -> Model.t -> Estimate.t
(** [estimate ?kv_dtype ~context model] is the memory [model] needs to run with
    a [context]-token window. [context] is clamped to [Model.max_context model].
    [kv_dtype] defaults to [F16].

    Raises [Invalid_argument] if [context] is not positive. *)

(** {1:verdicts Verdicts} *)

val default_context : int
(** [default_context] is the context length verdicts are judged at when the
    caller has no preference: 32768 tokens, the floor for comfortable agentic
    coding. *)

val min_useful_context : int
(** [min_useful_context] is the context length below which running a model is
    considered pointless: 8192 tokens. *)

module Verdict : sig
  (** Whether a model fits a memory budget. *)

  type t =
    | Fits  (** Fits at the requested context. *)
    | Tight of { max_context : int }
        (** Fits, but only up to [max_context] tokens — less than the requested
            context. *)
    | Wont_run
        (** Does not fit even at {!min_useful_context}. Sound grounds to refuse
            a download; a load attempt should still be possible with an explicit
            override. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same verdict. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

val max_context : ?kv_dtype:kv_dtype -> budget:int -> Model.t -> int option
(** [max_context ?kv_dtype ~budget model] is the largest context length, at most
    [Model.max_context model], at which [model]'s {!estimate} stays within
    [budget]. [None] when the weights and overhead alone exceed [budget].
    [kv_dtype] defaults to [F16]. *)

val verdict :
  ?kv_dtype:kv_dtype -> ?context:int -> budget:int -> Model.t -> Verdict.t
(** [verdict ?kv_dtype ?context ~budget model] judges [model] against [budget]
    bytes at the requested [context] (clamped to the model's maximum; defaults
    to {!default_context}): [Fits] when {!max_context} reaches it, [Wont_run]
    when {!max_context} falls below {!min_useful_context}, and [Tight] in
    between. [kv_dtype] defaults to [F16].

    Raises [Invalid_argument] if [context] is not positive. *)

(** {1:gguf GGUF headers} *)

module Gguf : sig
  (** Guard inputs read from the header of a GGUF file.

      GGUF files start with their metadata, so a prefix of the file — from a
      local read or an HTTP range request — is enough to recover every guard
      input except the file size. Parsing stops as soon as the fit-relevant keys
      are known, which typically takes a few kilobytes. *)

  type t
  (** Fit-relevant metadata parsed from a GGUF header. *)

  type error =
    | Truncated
        (** The prefix ended before the fit-relevant keys were found; retry with
            a longer prefix. *)
    | Malformed of string  (** Not a GGUF header, or a structural error. *)

  val of_prefix : string -> (t, error) result
  (** [of_prefix bytes] parses the fit-relevant metadata from [bytes], a prefix
      of a GGUF file (versions 2 and 3, any size prefix). *)

  val architecture : t -> string
  (** [architecture t] is the model architecture, e.g. ["qwen3moe"]. *)

  val name : t -> string option
  (** [name t] is the model's display name, when recorded. *)

  val model : weights_bytes:int -> t -> (Model.t, string) result
  (** [model ~weights_bytes t] derives guard inputs from [t] and the full file's
      size in bytes. [Error] names the metadata that was missing or
      inconsistent; well-formed model files always carry it.

      Raises [Invalid_argument] if [weights_bytes] is not positive. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] for diagnostics. *)
end
