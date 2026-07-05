(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session timestamps.

    Time values are inert Unix timestamps in milliseconds. They are suitable for
    saved session metadata and do not carry timezone, locale, or calendar
    formatting concerns. The module validates timestamp shape only; choosing the
    clock and deciding when to touch metadata belongs to the host. *)

type t
(** The type for non-negative Unix timestamps in milliseconds. *)

val of_unix_ms : int64 -> t
(** [of_unix_ms ms] is Unix timestamp [ms].

    Raises [Invalid_argument] if [ms] is negative. *)

val of_unix_seconds_float : float -> t
(** [of_unix_seconds_float seconds] is [seconds] truncated after conversion to
    milliseconds.

    Raises [Invalid_argument] if [seconds] is negative, non-finite, or too
    large. *)

val to_unix_ms : t -> int64
(** [to_unix_ms t] is [t] as Unix milliseconds. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same timestamp. *)

val compare : t -> t -> int
(** [compare a b] orders timestamps chronologically. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] as Unix milliseconds. *)

val jsont : t Jsont.t
(** [jsont] maps timestamps to JSON integers. Decoding rejects negative
    timestamps. *)
