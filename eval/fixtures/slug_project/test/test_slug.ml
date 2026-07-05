(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Slug.slugify "Hello World" = "hello-world");
  print_endline "ok"
