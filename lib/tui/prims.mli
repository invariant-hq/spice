(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared Mosaic view primitives.

    These primitives are used verbatim by nearly every view module in
    [spice_tui] — the styled inline segment, the head-first title truncation,
    and the fixed-width layout cell. They live here because they are genuinely
    cross-cutting, not because this is a bag to accrete helpers into: a helper
    that serves one surface belongs in that surface's module, and only a
    primitive shared across many view files is added here. *)

val seg : Mosaic.Ansi.Style.t -> string -> 'msg Mosaic.t
(** [seg style s] is the string [s] as one non-wrapping, non-shrinking inline
    text segment in [style] — the atom rows are built from. *)

val truncate_tail : width:int -> string -> string
(** [truncate_tail ~width s] is [s] truncated to [width] with a trailing ["…"]
    when it overflows, so a following right-aligned column keeps its place. Width
    is counted in bytes: exact for the ASCII titles and facts the stores hold, an
    approximation for wider text. A [width] of at most [1] returns [s]
    unchanged. *)

val cell : int -> 'msg Mosaic.t -> 'msg Mosaic.t
(** [cell w child] wraps [child] in a fixed [w]-column, one-row box that does not
    shrink. Rows use explicit cells rather than a flex spacer so columns land at
    deterministic positions, sidestepping the text-measurement width cache that
    can drop a widened tail (doc/plans/tui-next.md §Rules). *)
