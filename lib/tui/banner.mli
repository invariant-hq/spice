(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The brand banner: the home lockup block and the two-row transcript record.

    Two renderings of the same session-start facts (08-brand.md,
    04-header-footer.md §Banner record). The home block stages the two-row lockup
    in {!Theme.accent} with the facts to its right; the transcript record reuses
    that lockup — frozen, no animation — with the version, model, and cwd in a
    top-aligned right column, written at the top of the transcript when the first
    turn begins and scrolling away with the document. Both are pure views over
    the {!Snapshot.t}; the home's lockup animation frames are passed in as rows,
    the record's are the static {!Theme.lockup}. *)

val home : Snapshot.t -> rows:string list -> _ Mosaic.t
(** [home snapshot ~rows] is the centered brand for the stage: the two lockup
    [rows] in {!Theme.accent} (the current animation frame, laid out by {!Home})
    over one facts line — [v<version>] ({!Theme.muted}) and the model
    ({!Theme.default}), joined by {!Theme.separator}. The cwd is not here — the
    footer carries it (12-home.md §Layout). The lockup and the facts line are
    each centered horizontally. The ["pro plan"] fact is omitted: there is no
    host plan concept yet. *)

val record : Snapshot.t -> width:int -> _ Mosaic.t
(** [record snapshot ~width] is the two-row banner record: the frozen
    {!Theme.lockup} in {!Theme.accent} on the left, and a right column
    (top-aligned to the lockup rows) carrying [v<version> · <model>] on row 1 and
    the cwd on row 2, both {!Theme.muted}. Hanging permission and sandbox lines
    follow only when they are non-default (04-header-footer.md §Banner record).
    The cwd is home-relative and middle-ellipsised, the facts row tail-truncated,
    each to the right column's budget, so the record never wraps at [width]. *)
