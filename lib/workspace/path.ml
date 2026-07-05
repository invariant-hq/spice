(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { root : Root.t; rel : Spice_path.Rel.t }

let make ~root rel = { root; rel }
let root t = t.root
let rel t = t.rel
let abs t = Spice_path.Abs.append_rel (Root.dir t.root) t.rel
let is_root t = Spice_path.Rel.is_root t.rel
let basename t = Spice_path.Rel.basename t.rel
let parent t = Option.map (make ~root:t.root) (Spice_path.Rel.parent t.rel)

let add_component t component =
  Result.map (make ~root:t.root) (Spice_path.Rel.add_component t.rel component)

let append t suffix = make ~root:t.root (Spice_path.Rel.append t.rel suffix)
let same_root a b = Root.equal a.root b.root

let relativize ~root t =
  if same_root root t then Spice_path.Rel.relativize ~root:root.rel t.rel
  else None

let display t = Spice_path.Rel.to_string t.rel
let to_string t = Spice_path.Abs.to_string (abs t)
let equal a b = Root.equal a.root b.root && Spice_path.Rel.equal a.rel b.rel

let compare a b =
  match Root.compare a.root b.root with
  | 0 -> Spice_path.Rel.compare a.rel b.rel
  | order -> order

module Set = Set.Make (struct
  type nonrec t = t

  let compare = compare
end)

module Map = Map.Make (struct
  type nonrec t = t

  let compare = compare
end)

let pp ppf t = Format.pp_print_string ppf (to_string t)
