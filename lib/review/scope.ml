(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type side = Old | New

type t =
  | Feature
  | File of Spice_path.Rel.t
  | Hunk of {
      path : Spice_path.Rel.t;
      old_start : int;
      old_count : int;
      new_start : int;
      new_count : int;
    }
  | Line of side * Spice_path.Rel.t * int

let of_hunk ~path h =
  Hunk
    {
      path;
      old_start = Spice_diff.Hunk.old_start h;
      old_count = Spice_diff.Hunk.old_count h;
      new_start = Spice_diff.Hunk.new_start h;
      new_count = Spice_diff.Hunk.new_count h;
    }

let path = function
  | Feature -> None
  | File path -> Some path
  | Hunk { path; _ } -> Some path
  | Line (_, path, _) -> Some path

let side_equal a b =
  match (a, b) with Old, Old | New, New -> true | _ -> false

let side_rank = function Old -> 0 | New -> 1

let equal a b =
  match (a, b) with
  | Feature, Feature -> true
  | File a, File b -> Spice_path.Rel.equal a b
  | Hunk a, Hunk b ->
      Spice_path.Rel.equal a.path b.path
      && Int.equal a.old_start b.old_start
      && Int.equal a.old_count b.old_count
      && Int.equal a.new_start b.new_start
      && Int.equal a.new_count b.new_count
  | Line (aside, apath, aline), Line (bside, bpath, bline) ->
      side_equal aside bside
      && Spice_path.Rel.equal apath bpath
      && Int.equal aline bline
  | (Feature | File _ | Hunk _ | Line _), _ -> false

let rank = function Feature -> 0 | File _ -> 1 | Hunk _ -> 2 | Line _ -> 3
let then_compare c next = if c <> 0 then c else next ()

let compare a b =
  match (a, b) with
  | Feature, Feature -> 0
  | File a, File b -> Spice_path.Rel.compare a b
  | Hunk a, Hunk b ->
      then_compare (Spice_path.Rel.compare a.path b.path) (fun () ->
          then_compare (Int.compare a.old_start b.old_start) (fun () ->
              then_compare (Int.compare a.old_count b.old_count) (fun () ->
                  then_compare (Int.compare a.new_start b.new_start) (fun () ->
                      Int.compare a.new_count b.new_count))))
  | Line (aside, apath, aline), Line (bside, bpath, bline) ->
      then_compare (Spice_path.Rel.compare apath bpath) (fun () ->
          then_compare
            (Int.compare (side_rank aside) (side_rank bside))
            (fun () -> Int.compare aline bline))
  | _ -> Int.compare (rank a) (rank b)

let contains outer inner =
  match (outer, inner) with
  | Feature, _ -> true
  | File outer_path, _ -> (
      match path inner with
      | Some inner_path -> Spice_path.Rel.equal outer_path inner_path
      | None -> false)
  | Hunk h, Line (side, line_path, line) -> (
      Spice_path.Rel.equal h.path line_path
      &&
      match side with
      | Old ->
          h.old_count > 0 && line >= h.old_start
          && line < h.old_start + h.old_count
      | New ->
          h.new_count > 0 && line >= h.new_start
          && line < h.new_start + h.new_count)
  | Hunk _, _ -> equal outer inner
  | Line _, _ -> equal outer inner

let pp ppf = function
  | Feature -> Format.pp_print_string ppf "feature"
  | File path -> Format.fprintf ppf "file %s" (Spice_path.Rel.to_string path)
  | Hunk { path; old_start; old_count; new_start; new_count } ->
      Format.fprintf ppf "hunk %s -%d,%d +%d,%d"
        (Spice_path.Rel.to_string path)
        old_start old_count new_start new_count
  | Line (side, path, line) ->
      Format.fprintf ppf "line %s %s:%d"
        (match side with Old -> "old" | New -> "new")
        (Spice_path.Rel.to_string path)
        line
