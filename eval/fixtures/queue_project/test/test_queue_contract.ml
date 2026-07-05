(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Queue_contract.dequeue Queue_contract.empty = None);
  print_endline "ok"
