(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = Pending | Approved of { feature : Spice_digest.Identity.t }
type freshness = [ `Pending | `Approved | `Stale ]

let freshness t ~feature =
  match t with
  | Pending -> `Pending
  | Approved { feature = approved } ->
      if Spice_digest.Identity.equal approved feature then `Approved else `Stale

let equal a b =
  match (a, b) with
  | Pending, Pending -> true
  | Approved a, Approved b -> Spice_digest.Identity.equal a.feature b.feature
  | (Pending | Approved _), _ -> false

let pp ppf = function
  | Pending -> Format.pp_print_string ppf "pending"
  | Approved { feature } ->
      Format.fprintf ppf "approved %a" Spice_digest.Identity.pp feature
