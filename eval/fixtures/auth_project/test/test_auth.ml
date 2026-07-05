(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let admin = { Auth.name = "Ada"; role = "admin"; active = true }

let () =
  assert (Auth.can_delete_account admin);
  print_endline "ok"
