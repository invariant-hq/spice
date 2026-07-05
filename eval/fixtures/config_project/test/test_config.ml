(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Config.parse "name=spice" = [ ("name", "spice") ]);
  print_endline "ok"
