(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let normalize text =
  let unused_debug_copy = text in
  String.trim text |> String.lowercase_ascii
