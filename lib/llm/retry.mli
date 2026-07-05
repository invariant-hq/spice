(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Server retry guidance for provider adapters.

    Providers tell clients when to come back: numeric [retry-after] /
    [retry-after-ms] headers, IMF-fixdate [retry-after] headers, or
    provider-specific error bodies. This module is the one interpretation of
    that guidance shared by every Spice provider adapter; bodies stay
    provider-specific. *)

val max_honored_delay : float
(** [max_honored_delay] is the bound, in seconds, on any server-provided delay
    an adapter honors. A server cannot park a turn beyond it. *)

val after : now:float -> (string * string) list -> float option
(** [after ~now headers] is the server-requested retry delay in seconds, if any.

    [retry-after-ms] takes precedence, then numeric [retry-after] seconds, then
    IMF-fixdate [retry-after] (RFC 9110) interpreted against [now] in POSIX
    seconds. Results are non-negative; values are not bounded here — callers
    clamp with {!max_honored_delay}. Header names match case-insensitively.
    Unparseable values are [None]. *)

val budget : max_retries:int -> status:int -> int
(** [budget ~max_retries ~status] is the retry budget for a response status.

    [max_retries] bounds generic transient failures. Capacity statuses (429,
    503, and 529) clear on their own and usually state when, so they are retried
    up to a deeper budget — [max 5 max_retries] — unless [max_retries] is [0],
    which disables all retries. *)
