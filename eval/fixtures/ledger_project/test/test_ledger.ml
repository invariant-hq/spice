(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let entries =
  [
    { Ledger.account = "cash"; amount = 10 };
    { Ledger.account = "cash"; amount = -3 };
  ]

let () =
  assert (Ledger.balance "cash" entries = 7);
  print_endline "ok"
