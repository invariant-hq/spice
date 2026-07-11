(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The review nav pane: a directory-grouped tree of changed files, each file's
   CR comments always visible as children beneath it. Path-ordered (dirs then
   files sorted); one level of `▾ <dir>` grouping, no nested collapsing. The
   diff pane shows whatever the model cursor selects; this pane renders that
   selection and, when [on_click] is supplied, emits a cursor target per row. *)

(* {1 Model reading} *)

let path_string = Spice_path.Rel.to_string

let occ_path_string occ =
  Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ)

let occ_line occ = Spice_cr.Occurrence.line occ
let occ_is_valid occ = Result.is_ok (Spice_cr.Occurrence.comment occ)
let occ_in_file occ path = String.equal (occ_path_string occ) (path_string path)

let file_reviewed review file =
  Spice_review.file_reviewed review
    ~path:(Spice_review.Feature.File.path file)

(* {1 Cursor} *)

(* A file row is selected when the cursor sits anywhere in that file — its file
   scope or one of its hunks — since the nav has no hunk rows. *)
let file_selected review path =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Scope scope -> (
      match Spice_review.Scope.path scope with
      | Some p -> String.equal (path_string p) (path_string path)
      | None -> false)
  | Spice_review.Cursor.Cr _ -> false

let cr_selected review index =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Cr i -> Int.equal i index
  | Spice_review.Cursor.Scope _ -> false

(* {1 Tree} *)

(* [grouped] is the one level of depth the tree has: a row under a `▾ <dir>`
   header indents past it. Without it a root-level file — which gets no header —
   renders at the same depth as the previous group's children and reads as one
   of them. *)
type row =
  | Group of string  (** A `▾ <dir>` header; not selectable. *)
  | File of {
      path : Spice_path.Rel.t;
      status : Spice_review.Feature.File.status;
      selected : bool;
      reviewed : bool;
      grouped : bool;
    }
  | Cr of {
      occ : Spice_cr.Occurrence.t;
      index : int;
      selected : bool;
      grouped : bool;
    }

let cursor_of_row = function
  | File f -> Some (Spice_review.Cursor.Scope (Spice_review.Scope.File f.path))
  | Cr c -> Some (Spice_review.Cursor.Cr c.index)
  | Group _ -> None

type leaf =
  | File_leaf of Spice_review.Feature.File.t
  | Cr_leaf of int * Spice_cr.Occurrence.t

let leaf_path = function
  | File_leaf file -> path_string (Spice_review.Feature.File.path file)
  | Cr_leaf (_, occ) -> occ_path_string occ

let dir_of path = match Filename.dirname path with "." -> "" | dir -> dir

let file_row review ~grouped file =
  File
    {
      path = Spice_review.Feature.File.path file;
      status = Spice_review.Feature.File.status file;
      selected = file_selected review (Spice_review.Feature.File.path file);
      reviewed = file_reviewed review file;
      grouped;
    }

let cr_row review ~grouped index occ =
  Cr { occ; index; selected = cr_selected review index; grouped }

(* A file's CR children: every occurrence anchored in it, source order. *)
let cr_children review ~grouped indexed file =
  let path = Spice_review.Feature.File.path file in
  indexed
  |> List.filter (fun (_, occ) -> occ_in_file occ path)
  |> List.stable_sort (fun (_, a) (_, b) ->
      Int.compare (occ_line a) (occ_line b))
  |> List.map (fun (index, occ) -> cr_row review ~grouped index occ)

let build review =
  let feature = Spice_review.feature review in
  let files =
    List.stable_sort
      (fun a b ->
        String.compare
          (path_string (Spice_review.Feature.File.path a))
          (path_string (Spice_review.Feature.File.path b)))
      (Spice_review.Feature.files feature)
  in
  let feature_paths =
    List.map (fun f -> path_string (Spice_review.Feature.File.path f)) files
  in
  let indexed =
    Spice_review.crs review |> List.mapi (fun index occ -> (index, occ))
  in
  (* CRs anchored outside any changed file become their own leaves, grouped
     under their own directory. *)
  let outside =
    List.filter
      (fun (_, occ) -> not (List.mem (occ_path_string occ) feature_paths))
      indexed
  in
  let leaves =
    List.map (fun f -> File_leaf f) files
    @ List.map (fun (i, o) -> Cr_leaf (i, o)) outside
  in
  let leaves =
    List.stable_sort
      (fun a b -> String.compare (leaf_path a) (leaf_path b))
      leaves
  in
  let rec emit current = function
    | [] -> []
    | leaf :: rest ->
        let dir = dir_of (leaf_path leaf) in
        let grouped = not (String.equal dir "") in
        let header =
          if grouped && not (String.equal dir current) then [ Group dir ] else []
        in
        let body =
          match leaf with
          | File_leaf file ->
              file_row review ~grouped file
              :: cr_children review ~grouped indexed file
          | Cr_leaf (index, occ) -> [ cr_row review ~grouped index occ ]
        in
        header @ body @ emit dir rest
  in
  emit "\000" leaves

let selected_index rows =
  let is_selected = function
    | File f -> f.selected
    | Cr c -> c.selected
    | Group _ -> false
  in
  let rec find i = function
    | [] -> None
    | row :: rest -> if is_selected row then Some i else find (i + 1) rest
  in
  find 0 rows

(* {1 Rendering} *)

let status_cell = function
  | Spice_review.Feature.File.Added -> ("A", Style.success)
  | Spice_review.Feature.File.Modified -> ("M", Style.warning)
  | Spice_review.Feature.File.Deleted -> ("D", Style.error)

let mark_cell reviewed =
  let glyph = if reviewed then Style.todo_done else Style.todo_pending in
  let style = if reviewed then Style.success else Mosaic.Ansi.Style.default in
  (glyph ^ " ", style)

let basename path = Filename.basename (path_string path)

let cr_text occ =
  match Spice_cr.Occurrence.comment occ with
  | Ok cr -> Spice_cr.to_string cr
  | Error _ -> Spice_cr.Occurrence.raw occ

let cr_resolved occ =
  match Spice_cr.Occurrence.comment occ with
  | Ok cr -> (
      match Spice_cr.status cr with
      | Spice_cr.Status.Resolved _ -> true
      | Spice_cr.Status.Open _ -> false)
  | Error _ -> false

let malformed_message occ =
  match Spice_cr.Occurrence.comment occ with
  | Error error -> Spice_cr.Error.message error
  | Ok _ -> ""

let spacer = Mosaic.box ~flex_grow:1. []

(* Everything dims to faint while a compose dialog owns the screen. *)
let dim ~dimmed style = if dimmed then Style.faint else style

(* The cursor glyph: accent when its pane holds focus, muted otherwise, faint
   while dimmed. *)
let cursor_cell ~focused ~dimmed selected =
  let style =
    if dimmed then Style.faint
    else if focused then Style.accent
    else Style.muted
  in
  Mosaic.text ~style ~wrap:`None ~flex_shrink:0.
    (if selected then Style.cursor else Style.cursor_blank)

let on_mouse_of on_click row =
  match (on_click, cursor_of_row row) with
  | Some f, Some cursor ->
      Some
        (fun ev ->
          match Mosaic.Event.Mouse.kind ev with
          | Mosaic.Event.Mouse.Down { button = Mosaic.Event.Mouse.Left } ->
              Some (f cursor)
          | _ -> None)
  | _ -> None

let row_box ?on_mouse nodes =
  Mosaic.box ?on_mouse ~flex_direction:Mosaic.Flex_direction.Row
    ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px 1 }
    nodes

(* One level of depth: a grouped row hangs under its `▾ <dir>` header. *)
let indent ~grouped base = if grouped then base ^ "  " else base

let render ~focused ~dimmed ~on_click row =
  match row with
  | Group dir ->
      Mosaic.text ~style:(dim ~dimmed Style.muted) ~wrap:`None ~truncate:true
        (" " ^ Style.tree_group ^ " " ^ dir)
  | File f ->
      let mark, mark_style = mark_cell f.reviewed in
      let letter, letter_style = status_cell f.status in
      let name_style =
        if f.selected && focused then Style.accent
        else Mosaic.Ansi.Style.default
      in
      row_box ?on_mouse:(on_mouse_of on_click row)
        [
          Mosaic.text ~wrap:`None ~flex_shrink:0.
            (indent ~grouped:f.grouped " ");
          cursor_cell ~focused ~dimmed f.selected;
          Mosaic.text ~style:(dim ~dimmed mark_style) ~wrap:`None
            ~flex_shrink:0. mark;
          Mosaic.text ~style:(dim ~dimmed name_style) ~wrap:`None ~truncate:true
            ~flex_shrink:1. (basename f.path);
          spacer;
          Mosaic.text ~style:(dim ~dimmed letter_style) ~wrap:`None
            ~flex_shrink:0. (letter ^ " ");
        ]
  | Cr c ->
      let malformed = not (occ_is_valid c.occ) in
      let base =
        if malformed then Style.error
        else if cr_resolved c.occ then Style.faint
        else Style.muted
      in
      let style =
        if dimmed then Style.faint
        else if c.selected && focused then Style.accent
        else base
      in
      let text =
        if malformed then Style.problem ^ malformed_message c.occ
        else cr_text c.occ
      in
      row_box ?on_mouse:(on_mouse_of on_click row)
        [
          Mosaic.text ~wrap:`None ~flex_shrink:0.
            (indent ~grouped:c.grouped "   ");
          cursor_cell ~focused ~dimmed c.selected;
          Mosaic.text ~style ~wrap:`None ~truncate:true ~flex_shrink:1. text;
          spacer;
        ]

(* Reserve two rows for the ↑/↓ overflow markers so the window plus markers
   never exceed the pane height. *)
let max_list_rows height =
  match height with None -> 16 | Some height -> max 1 (height - 2)

let view ?width:_ ?height ?(focused = true) ?(dimmed = false) ?on_click review =
  let rows = build review in
  let count = List.length rows in
  let selected = Option.value (selected_index rows) ~default:0 in
  let limit = max_list_rows height in
  let start, length = Style.window ~limit ~selected ~count in
  let above = if start > 0 then [ Style.scrolled_above start ] else [] in
  let below =
    if start + length < count then
      [ Style.scrolled_below (count - start - length) ]
    else []
  in
  let shown =
    rows
    |> List.filteri (fun i _ -> i >= start && i < start + length)
    |> List.map (render ~focused ~dimmed ~on_click)
  in
  above @ shown @ below
