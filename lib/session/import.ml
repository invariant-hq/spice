(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* House helpers — keep byte-identical across lib/*/import.ml copies. *)

let invalid_arg' m fn msg = invalid_arg (m ^ "." ^ fn ^ ": " ^ msg)
let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message -> decode_error message
