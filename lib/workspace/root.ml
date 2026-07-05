(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { key : string; dir : Spice_path.Abs.t }

let make ?key dir =
  let key = Option.value key ~default:(Spice_path.Abs.to_string dir) in
  if String.is_empty key then
    invalid_arg "Spice_workspace.Root.make: key must not be empty";
  { key; dir }

let dir t = t.dir
let key t = t.key
let same_key a b = String.equal a.key b.key
let equal a b = same_key a b && Spice_path.Abs.equal a.dir b.dir

let compare a b =
  match String.compare a.key b.key with
  | 0 -> Spice_path.Abs.compare a.dir b.dir
  | order -> order

let pp ppf t = Spice_path.Abs.pp ppf t.dir
