(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Token usage reported by a model request.

    Usage is provider-reported accounting data. Lanes are kept separate so
    callers can choose their own billing, display, or aggregation policy. *)

type t = private {
  input : int;
  output : int;
  reasoning : int;
  cache_read : int;
  cache_write : int;
}
(** The type for token usage.

    All counts are non-negative and lanes are disjoint:

    - [input] is non-cached input;
    - [cache_read] is cached input read;
    - [cache_write] is cached input written;
    - [output] is visible output;
    - [reasoning] is non-visible reasoning output. *)

val make :
  input:int ->
  output:int ->
  ?reasoning:int ->
  ?cache_read:int ->
  ?cache_write:int ->
  unit ->
  t
(** [make ~input ~output ?reasoning ?cache_read ?cache_write ()] is token usage.
    Optional counts default to [0].

    Raises [Invalid_argument] if any count is negative. *)

val zero : t
(** [zero] is usage with every count set to [0]. *)

val add : t -> t -> t
(** [add a b] is the lane-wise sum of [a] and [b].

    Raises [Invalid_argument] if any lane overflows. *)

val input_total : t -> int
(** [input_total t] is [t.input + t.cache_read + t.cache_write].

    Raises [Invalid_argument] if the total overflows. *)

val output_total : t -> int
(** [output_total t] is [t.output + t.reasoning].

    Raises [Invalid_argument] if the total overflows. *)

val sum_lanes : t -> int
(** [sum_lanes t] is the sum of every disjoint lane in [t].

    Raises [Invalid_argument] if the total overflows. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same counts. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps usage values to JSON objects.

    Decoding errors if any lane is negative. *)
