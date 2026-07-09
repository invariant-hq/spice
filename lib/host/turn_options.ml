(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* [model] conditions no option yet, so it is discarded here; it stays in the
   contract because the first conditioned axis resolves from it, and frontends
   already thread it. See doc/architecture.md. *)
let resolve ~model:_ ?reasoning_effort () =
  Spice_llm.Request.Options.make ?reasoning_effort ()
