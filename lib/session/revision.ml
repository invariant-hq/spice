(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = string

let of_string s = s
let to_string t = t
let equal = String.equal
let pp ppf t = Format.pp_print_string ppf t
