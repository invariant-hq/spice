(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let slugify text =
  text |> String.lowercase_ascii
  |> String.map (fun c -> if c = ' ' then '-' else c)
