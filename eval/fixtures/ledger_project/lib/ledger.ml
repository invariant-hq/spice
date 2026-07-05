(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type entry = {
  account : string;
  amount : int;
}

let balance account entries =
  entries
  |> List.filter (fun entry -> entry.account = account)
  |> List.fold_left (fun total entry -> total + abs entry.amount) 0
