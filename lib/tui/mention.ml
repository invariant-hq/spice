(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type item =
  | File of Spice_path.Rel.t
  | Directory of Spice_path.Rel.t
  | Agent_thread of { name : string }

type dir_state = Loading | Loaded of item list | Failed of string

type t = {
  query : string;
  selected : int;
  expanded : Spice_path.Rel.Set.t;
  dirs : dir_state Spice_path.Rel.Map.t;
}

let make ?(query = "") () =
  {
    query;
    selected = 0;
    expanded = Spice_path.Rel.Set.empty;
    dirs = Spice_path.Rel.Map.empty;
  }

(* A directory renders with a trailing "/" so its kind reads without a second
   glyph; files and directories share the "+" mark, threads the "*" mark. *)
let item_display = function
  | File path -> Spice_path.Rel.to_string path
  | Directory path -> Spice_path.Rel.to_string path ^ "/"
  | Agent_thread { name } -> name

let item_basename = function
  | File path | Directory path -> Spice_path.Rel.basename path
  | Agent_thread { name } -> Some name

let item_glyph = function
  | File _ | Directory _ -> Theme.kind_file
  | Agent_thread _ -> Theme.kind_thread

let normalize_query query = query |> String.trim |> String.lowercase_ascii

let contains ~needle haystack =
  let haystack = String.lowercase_ascii haystack in
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop index =
      if index + needle_len > haystack_len then false
      else if String.equal (String.sub haystack index needle_len) needle then
        true
      else loop (index + 1)
    in
    loop 0

let item_matches ~query item =
  String.equal query ""
  || contains ~needle:query (item_display item)
  ||
  match item_basename item with
  | Some name -> contains ~needle:query name
  | None -> false

let dir_state dir t = Spice_path.Rel.Map.find_opt dir t.dirs

(* The flat, in-order list of rows: each loaded directory's kept items, with an
   expanded directory's children inlined right after it. A directory that does
   not itself match the filter is dropped but still descended, so its matching
   children survive. Loading and failed subdirectories contribute nothing; the
   whole-list loading and failure states are the view's ({!view}). *)
let visible_items t =
  let query = normalize_query t.query in
  let rec collect_dir acc dir =
    match dir_state dir t with
    | Some (Loaded items) -> List.fold_left collect_item acc items
    | Some Loading | Some (Failed _) | None -> acc
  and collect_item acc item =
    let acc = if item_matches ~query item then item :: acc else acc in
    match item with
    | Directory path when Spice_path.Rel.Set.mem path t.expanded ->
        collect_dir acc path
    | Directory _ | File _ | Agent_thread _ -> acc
  in
  List.rev (collect_dir [] Spice_path.Rel.root)

let clamp t =
  let count = List.length (visible_items t) in
  let selected =
    if count = 0 then 0 else t.selected |> max 0 |> min (count - 1)
  in
  { t with selected }

let with_query query t =
  let t =
    if String.equal query t.query then t else { t with query; selected = 0 }
  in
  clamp t

let select_by offset t =
  match List.length (visible_items t) with
  | 0 -> t
  | count -> { t with selected = (t.selected + offset + count) mod count }

let select_next t = select_by 1 t
let select_previous t = select_by (-1) t

(* The directories still worth a read: the root when it has no state yet, plus
   every expanded directory in the same state. *)
let needed_dirs t =
  let unloaded dir =
    match dir_state dir t with None -> true | Some _ -> false
  in
  let expanded =
    Spice_path.Rel.Set.elements t.expanded |> List.filter unloaded
  in
  if unloaded Spice_path.Rel.root then Spice_path.Rel.root :: expanded
  else expanded

let request_loads t =
  let dirs = needed_dirs t in
  let marked =
    List.fold_left
      (fun map dir -> Spice_path.Rel.Map.add dir Loading map)
      t.dirs dirs
  in
  ({ t with dirs = marked }, dirs)

let loaded ~dir result t =
  let state =
    match result with
    | Ok items -> Loaded items
    | Error message -> Failed message
  in
  clamp { t with dirs = Spice_path.Rel.Map.add dir state t.dirs }

let selected_item t = List.nth_opt (visible_items t) t.selected
let enter t = selected_item t

type tab_result = Descended of t | Chosen of item | No_selection

let tab t =
  match selected_item t with
  | None -> No_selection
  | Some (Directory path) ->
      Descended
        (clamp { t with expanded = Spice_path.Rel.Set.add path t.expanded })
  | Some ((File _ | Agent_thread _) as item) -> Chosen item

(* Cursor column (2) and the kind glyph plus its space (2) sit outside the path
   budget; the path middle-truncates so the root and the filename both survive
   (03-composer.md §File completion open). *)
let row ~selected ~width item =
  let budget = max 1 (width - 4) in
  let display =
    Path_display.middle_truncate ~width:budget (item_display item)
  in
  let style = if selected then Some Theme.accent else None in
  [ Completion_list.segment ?style (item_glyph item ^ " " ^ display) ]

let view ~width t =
  match dir_state Spice_path.Rel.root t with
  | None | Some Loading -> Completion_list.note "loading files…"
  | Some (Failed message) -> Completion_list.error message
  | Some (Loaded []) -> Completion_list.note "no files"
  | Some (Loaded (_ :: _)) -> (
      match visible_items t with
      | [] -> Completion_list.note "no matching files"
      | items ->
          List.mapi
            (fun index item -> row ~selected:(index = t.selected) ~width item)
            items
          |> Completion_list.view ~selected:t.selected)
