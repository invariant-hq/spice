(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Input-only planned-change evidence rendering shared by the file tools.

   Evidence bytes must originate from the decoded tool input — never from
   filesystem reads — so permission planning stays deterministic across block
   and resume, and rendering evidence can never disclose file content the
   model has not already supplied. [Spice_diff] fits that law by construction:
   it renders caller-supplied strings and reads nothing.

   Everything here is bounded: this code runs on the host loop before any
   review or denial, on model-controlled input, so no unbounded diff work is
   acceptable. Creation counts are direct line counts (linear); modify counts
   come from the display-limited render and are omitted when the limits elide
   the hunks — counts are exact when present, never estimated. *)

module Change = Spice_permission.Request.Change
module Diff = Spice_diff

(* One file change per access. Oversized or pathological inputs render as
   header-plus-omission notes; the limits are display policy, not contract,
   and [max_edit_distance] also bounds the diff computation itself. *)
let limits =
  Diff.Limits.make ~max_files:1 ~max_file_bytes:32_768 ~max_lines:4_096
    ~max_edit_distance:10_000 ()

let label path = Diff.Label.escaped (Spice_workspace.Path.to_string path)

let rendered_diff change =
  let text = Diff.to_string (Diff.render ~limits [ change ]) in
  if String.length text = 0 then None else Some text

let creation ~path contents =
  Change.make
    ?diff:
      (rendered_diff (Diff.File_change.create ~label:(label path) ~contents))
    ~additions:(Text_helpers.logical_line_count contents)
    ~removals:0 ()

(* The current contents cannot be read under the input-only rule, so an
   overwrite renders as a full replacement and omits the removal count. *)
let replacement ~path contents =
  Change.make
    ?diff:
      (rendered_diff (Diff.File_change.create ~label:(label path) ~contents))
    ~additions:(Text_helpers.logical_line_count contents)
    ()

let modify ~path ~before ~after =
  let change = Diff.File_change.modify ~label:(label path) ~before ~after in
  let rendered = Diff.render ~limits [ change ] in
  let stats = Diff.stats rendered in
  (* Elided hunks carry no counts; report them only when nothing was omitted. *)
  let known = Diff.omitted rendered = 0 in
  let text = Diff.to_string rendered in
  Change.make
    ?diff:(if String.length text = 0 then None else Some text)
    ?additions:(if known then Some stats.Diff.additions else None)
    ?removals:(if known then Some stats.Diff.deletions else None)
    ()
