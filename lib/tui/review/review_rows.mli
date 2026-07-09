(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The review nav pane: a directory-grouped tree of changed files, each file's
    CR comments always visible as children beneath it.

    Path-ordered (directories then files sorted), one level of [▾ <dir>]
    grouping with no nested collapsing. The pane renders the selection the model
    cursor holds and, when [on_click] is supplied, emits a cursor target per
    row. Pure: it reads the review and produces rows; the component owns the
    cursor. *)

val view :
  ?width:int ->
  ?height:int ->
  ?focused:bool ->
  ?dimmed:bool ->
  ?on_click:(Spice_review.Cursor.t -> 'a) ->
  Spice_review.t ->
  'a Mosaic.t list
(** [view ?width ?height ?focused ?dimmed ?on_click review] is the windowed nav
    rows for [review]: a [▾ dir] group per directory, then each file's [❯ ]
    cursor (accent when [focused], muted otherwise, faint when [dimmed]),
    [[ ]]/[[✓]] mark, middle-ellipsised basename, and right-aligned [A]/[M]/[D]
    status letter, with the file's CR children ([! …] for malformed ones)
    beneath it. The list is windowed to [height] rows with [↑/↓ N more] overflow
    markers. When [on_click] is supplied, each selectable row reports its
    {!Spice_review.Cursor.t} on a left mouse-down. *)
