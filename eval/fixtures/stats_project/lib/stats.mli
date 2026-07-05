(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

val mean : float list -> float
(** [mean values] is the arithmetic mean of [values].

    Raises [Invalid_argument] if [values] is empty. *)

val median : float list -> float
(** [median values] is the median of [values]. For an even number of values,
    it is the arithmetic mean of the two middle sorted values.

    Raises [Invalid_argument] if [values] is empty. *)
