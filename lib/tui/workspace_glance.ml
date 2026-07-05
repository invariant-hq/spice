(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

let sep = seg Theme.muted Theme.separator
let plural n = if n = 1 then "" else "s"

(* " · " is three columns (the multibyte middot is one). *)
let sep_cols = 3

(* Each fact row indents two columns under the pane's [workspace] section header
   (doc/plans/tui-next-side-panel.md §Sections) — the indentation that, with the
   flush header and the inter-section blank, is the whole hierarchy device. The
   todo board's rows share this margin. *)
let indent = 2

let row segs =
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb indent 0 0 0)
    ~size:{ width = auto; height = px 1 }
    segs

(* dune leads and is always shown — spice's core loop (12-home.md §Workspace
   block). Connectivity is a word here (the pane has no glyph column); a failing
   build is the one caution, the rest muted weather. *)
let dune_row dune =
  let open Spice_ocaml_dune.Rpc.Instance.Health in
  match dune with
  | Clean ->
      row
        [ seg Theme.muted "dune connected"; sep; seg Theme.muted "build clean" ]
  | Failing n ->
      row
        [
          seg Theme.muted "dune connected";
          sep;
          seg Theme.warning (Printf.sprintf "%d error%s" n (plural n));
        ]
  | Unknown ->
      row
        [
          seg Theme.muted "dune connected"; sep; seg Theme.muted "build unknown";
        ]
  | Disconnected -> row [ seg Theme.muted "dune disconnected" ]

let worktree_row (stats : Spice_diff.stats) =
  let files = stats.Spice_diff.files in
  row
    [
      seg Theme.muted (Printf.sprintf "worktree %d file%s" files (plural files));
      sep;
      seg Theme.success (Printf.sprintf "+%d" stats.Spice_diff.additions);
      seg Ansi.Style.default " ";
      seg Theme.error (Printf.sprintf "−%d" stats.Spice_diff.deletions);
    ]

let crs_row (counts : Spice_cr.Occurrence.counts) =
  row
    [
      seg Theme.muted
        (Printf.sprintf "CRs %d open" counts.Spice_cr.Occurrence.open_);
      sep;
      seg Theme.muted
        (Printf.sprintf "%d addressed" counts.Spice_cr.Occurrence.addressed);
    ]

let session_row ~width (s : Home.Brief.session) =
  let age = s.Home.Brief.age in
  (* Leave room for the [indent], the two quote marks, the [ · ] and the age. *)
  let budget = max 1 (width - indent - 2 - sep_cols - String.length age) in
  let title = truncate_tail ~width:budget s.Home.Brief.title in
  row [ seg Ansi.Style.default ("\"" ^ title ^ "\""); sep; seg Theme.muted age ]

let view ~width ~max_rows (brief : Home.Brief.t) =
  let opt f = function Some x -> [ f x ] | None -> [] in
  let rows =
    dune_row brief.Home.Brief.dune
    :: (opt worktree_row brief.Home.Brief.worktree
       @ opt crs_row brief.Home.Brief.crs
       @ opt (session_row ~width) brief.Home.Brief.session)
  in
  List.filteri (fun i _ -> i < max 1 max_rows) rows
