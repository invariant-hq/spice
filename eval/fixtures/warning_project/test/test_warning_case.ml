(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Warning_case.normalize "  Hello  " = "hello");
  print_endline "ok"
