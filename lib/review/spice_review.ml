(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = Error
module Feature = Feature
module Scope = Scope
module Mark = Mark
module Verdict = Verdict
module Cursor = Cursor

type t = Review.t

let v = Review.v
let refresh = Review.refresh
let feature = Review.feature
let crs = Review.crs
let cr = Review.cr
let marks = Review.marks
let mark = Review.mark
let effective_mark = Review.effective_mark
let is_reviewed = Review.is_reviewed
let verdict = Review.verdict
let verdict_freshness = Review.verdict_freshness
let cursor = Review.cursor
let files = Review.files
let unit_scopes = Review.unit_scopes
let file_unit_scopes = Review.file_unit_scopes
let units = Review.units
let reviewed_units = Review.reviewed_units
let open_crs = Review.open_crs
let progress = Review.progress
let is_complete = Review.is_complete
let mark_reviewed = Review.mark_reviewed
let mark_unreviewed = Review.mark_unreviewed
let clear_mark = Review.clear_mark
let approve = Review.approve
let set_pending = Review.set_pending
let set_cursor = Review.set_cursor
let move_cursor = Review.move_cursor
let equal = Review.equal
let pp = Review.pp

module Live = Live
module Op = Op
module Persist = Persist
