(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* [model] conditions no option yet, so it is discarded here; it stays in the
   contract because the first conditioned axis (sampling per
   doc/design-notes/model-conditioning.md §5) resolves from it, and frontends
   already thread it. *)
let resolve ~model:_ ?reasoning_effort () =
  Spice_llm.Request.Options.make ?reasoning_effort ()
