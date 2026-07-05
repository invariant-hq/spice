(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Time = Spice_session.Time

let check_time ~created_at ~transition_time ~error status =
  match transition_time status with
  | None -> Ok ()
  | Some time when Time.compare time created_at >= 0 -> Ok ()
  | Some _ -> Error (error status)
