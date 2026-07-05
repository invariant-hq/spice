(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let () =
  assert (Words.rev_words "alpha beta gamma" = "gamma beta alpha");
  assert (Words.rev_words "solo" = "solo");
  print_endline "ok"
