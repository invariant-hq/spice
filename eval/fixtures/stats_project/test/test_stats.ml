(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Stats.mean [ 1.; 2.; 3. ] = 2.);
  assert (Stats.median [ 3.; 1.; 2. ] = 2.);
  print_endline "ok"
