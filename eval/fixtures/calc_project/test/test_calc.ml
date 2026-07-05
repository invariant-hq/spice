(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Calc.clamp ~low:0 ~high:10 5 = 5);
  print_endline "ok"
