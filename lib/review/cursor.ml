(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = Scope of Scope.t | Cr of int

type move =
  | Next
  | Previous
  | Next_file
  | Previous_file
  | Next_cr
  | Previous_cr
  | First
  | Last

let feature = Scope Scope.Feature

let equal a b =
  match (a, b) with
  | Scope a, Scope b -> Scope.equal a b
  | Cr a, Cr b -> Int.equal a b
  | (Scope _ | Cr _), _ -> false

let pp ppf = function
  | Scope scope -> Scope.pp ppf scope
  | Cr index -> Format.fprintf ppf "cr %d" index
