(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Jsont decode-error helpers shared by the artifact codecs.

    Every artifact validates decoded JSON through its type's smart constructor —
    the single validation path — and reports a rejected value as a Jsont decode
    error. These two functions are that bridge, so no module copies the
    [Jsont.Error.msg] one-liner or the [Ok]/[Error] unwrap. *)

val error : string -> 'a
(** [error message] reports [message] as a Jsont decode error with no metadata.
    It does not return. *)

val or_error : ('a, string) result -> 'a
(** [or_error r] is [v] when [r] is [Ok v], and {!error} [m] when [r] is
    [Error m]. A codec's decoder runs the smart constructor and passes its
    result here. *)
