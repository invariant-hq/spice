(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let mean values =
  match values with
  | [] -> invalid_arg "mean: empty"
  | _ :: _ ->
      let total = List.fold_left ( +. ) 0. values in
      total /. float_of_int (List.length values)

let median values =
  match List.sort Float.compare values with
  | [] -> invalid_arg "median: empty"
  | sorted -> List.nth sorted (List.length sorted / 2)
