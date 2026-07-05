(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Add of { path : Spice_path.Rel.t; line : int; cr : Spice_cr.t }
  | Replace of { occurrence : Spice_cr.Occurrence.t; cr : Spice_cr.t }
  | Remove of { occurrence : Spice_cr.Occurrence.t }

let path = function
  | Add { path; _ } -> path
  | Replace { occurrence; _ } | Remove { occurrence } ->
      Spice_cr.Occurrence.path occurrence
