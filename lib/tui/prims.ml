(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

let seg style s = text ~style ~wrap:`None ~flex_shrink:0. s

(* Byte-based head-first truncation: exact for the ASCII titles the stores hold,
   an approximation for wider text. *)
let truncate_tail ~width s =
  if width <= 1 || String.length s <= width then s
  else String.sub s 0 (width - 1) ^ "…"

(* Explicit fixed-width cell rather than a flex spacer, so columns land at
   deterministic positions without relying on text-measurement width, which
   caches a node's width across renders and can drop a widened tail
   (doc/plans/tui-next.md §Rules). *)
let cell w child =
  box ~flex_shrink:0. ~size:{ width = px w; height = px 1 } [ child ]
