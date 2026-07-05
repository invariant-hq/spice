(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Provider-neutral token usage observed during an eval run.

    Usage values are durable result data. They intentionally do not depend on a
    provider runtime type; runner and bridge code converts provider-specific
    counters into this shape before constructing {!Result.t}. *)

(** {1:types Types} *)

type t = {
  input : int;
      (** Non-cached input tokens, when reported separately by the provider. *)
  output : int;
      (** Non-reasoning output tokens, when reported separately by the provider.
      *)
  cache_read : int;  (** Input tokens read from a prompt cache. *)
  cache_write : int;  (** Input tokens written to a prompt cache. *)
  reasoning : int;
      (** Output tokens used for reasoning or hidden chain-of-thought lanes. *)
}
(** Token counts reported by an agent adapter.

    All fields are non-negative. [input] and [output] are the non-cached,
    non-reasoning lanes when the provider exposes them separately. *)

(** {1:constructors Constructors} *)

val make :
  ?input:int ->
  ?output:int ->
  ?cache_read:int ->
  ?cache_write:int ->
  ?reasoning:int ->
  unit ->
  t
(** [make] constructs usage with missing lanes defaulting to [0].

    Raises [Invalid_argument] if any lane is negative. *)

(** {1:queries Queries} *)

val input_total : t -> int
(** [input_total t] is [input + cache_read + cache_write]. *)

val output_total : t -> int
(** [output_total t] is [output + reasoning]. *)

(** {1:formatting Formatting and codecs} *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for human-readable diagnostics. The output is not a
    stable serialization format. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same lane counts. *)

val jsont : t Jsont.t
(** [jsont] maps usage values to JSON objects. Decoding validates the same
    invariants as {!make}. *)
