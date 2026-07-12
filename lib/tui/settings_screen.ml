(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type tab = Config | Status | Usage | Skills

module Config = struct
  type value =
    | Enum of { current : string; options : string list }
    | Toggle of bool
    | Text of string
    | Managed of string

  type row = {
    field : string;
    label : string;
    value : value;
    is_default : bool;
    danger : string option;
  }

  type group = { title : string; rows : row list }
  type t = { groups : group list; sources : string }
end

module Status = struct
  type fact = { label : string; value : string }
  type t = { rows : fact list; session_id : string option }
end

module Usage = struct
  type lane = { label : string; tokens : int }

  type t = {
    has_turns : bool;
    model : string;
    lanes : lane list;
    cost : string;
    scope : string;
  }
end

module Skills = struct
  type row = {
    name : string;
    state : string;
    source : string;
    cost : int;
    enabled : bool;
    description : string option;
  }

  type t = { rows : row list; budget : int; available : bool }
end

type facts = {
  config : Config.t;
  status : Status.t;
  usage : Usage.t;
  skills : Skills.t;
}

(* The filter line is either closed (letters are the keymap) or open (printables
   narrow); esc closes it before it leaves the screen (03-ia §The filter law). *)
type filter = Closed | Open of string

(* The skills tab's row order, cycled by [t] (03-ia §Settings). *)
type sort = By_name | By_state | By_cost

(* The one in-place affordance a selected config row may wear: the enum's inline
   [●] radio, or the open-shape field's text input. Both live on the row; the
   model row is never edited here (it defers to the model panel). *)
type editing =
  | Browsing
  | Choosing of { field : string; options : string list; cursor : int }
  | Inputting of { field : string; text : string }

type ready = {
  facts : facts;
  tab : tab;
  filter : filter;
  config_sel : int; (* index into the visible config rows *)
  skills_sel : int; (* index into the visible skill rows *)
  sort : sort;
  editing : editing;
}

type t = Loading of { tab : tab } | Load_error of string | Ready of ready
type msg = Key of Screen.key

type event =
  | Stay
  | Close
  | Open_model_panel
  | Write_field of { field : string; value : string option }
  | Toggle_skill of string
  | Copy of string

let loading ~tab = Loading { tab }
let failed message = Load_error message
let tabs = [ Config; Status; Usage; Skills ]

(* Case-insensitive substring match, as the quick-switch panel filters. *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else loop (i + 1)
    in
    loop 0

(* The config rows flattened across their family groups, each paired with its
   group title so the renderer can head a group when the title changes. *)
let config_flat facts =
  List.concat_map
    (fun (g : Config.group) ->
      List.map (fun r -> (g.Config.title, r)) g.Config.rows)
    facts.config.Config.groups

let config_visible ready =
  match ready.filter with
  | Closed | Open "" -> config_flat ready.facts
  | Open q ->
      let needle = String.lowercase_ascii q in
      List.filter
        (fun (_, (row : Config.row)) ->
          contains ~needle (String.lowercase_ascii row.Config.label))
        (config_flat ready.facts)

let sort_skills sort rows =
  let cmp (a : Skills.row) (b : Skills.row) =
    match sort with
    | By_name -> String.compare a.Skills.name b.Skills.name
    | By_state -> (
        match String.compare a.Skills.state b.Skills.state with
        | 0 -> String.compare a.Skills.name b.Skills.name
        | c -> c)
    | By_cost -> (
        match Int.compare b.Skills.cost a.Skills.cost with
        | 0 -> String.compare a.Skills.name b.Skills.name
        | c -> c)
  in
  List.stable_sort cmp rows

let skills_visible ready =
  let sorted = sort_skills ready.sort ready.facts.skills.Skills.rows in
  match ready.filter with
  | Closed | Open "" -> sorted
  | Open q ->
      let needle = String.lowercase_ascii q in
      List.filter
        (fun (row : Skills.row) ->
          contains ~needle (String.lowercase_ascii row.Skills.name))
        sorted

(* The selection always names a visible row: clamp the active tab's index into
   its visible count whenever the filter, the sort, or the facts change it. *)
let clamp_sel ready =
  let clamp count sel = if count = 0 then 0 else max 0 (min sel (count - 1)) in
  match ready.tab with
  | Config ->
      {
        ready with
        config_sel = clamp (List.length (config_visible ready)) ready.config_sel;
      }
  | Skills ->
      {
        ready with
        skills_sel = clamp (List.length (skills_visible ready)) ready.skills_sel;
      }
  | Status | Usage -> ready

let loaded facts t =
  match t with
  | Loading { tab } ->
      Ready
        (clamp_sel
           {
             facts;
             tab;
             filter = Closed;
             config_sel = 0;
             skills_sel = 0;
             sort = By_name;
             editing = Browsing;
           })
  | Load_error _ ->
      Ready
        {
          facts;
          tab = Config;
          filter = Closed;
          config_sel = 0;
          skills_sel = 0;
          sort = By_name;
          editing = Browsing;
        }
  (* A write's own reload lands the user where they were, now reading the
     persisted value: keep the tab, filter, selections, sort, and editing. *)
  | Ready ready -> Ready (clamp_sel { ready with facts })

let key ev =
  match Screen.classify ev with
  | Screen.Action Screen.Other -> None
  | k -> Some (Key k)

(* Drop the last UTF-8 scalar, walking back over continuation bytes. *)
let drop_last s =
  let n = String.length s in
  if n = 0 then s
  else
    let rec back i =
      if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then back (i - 1) else i
    in
    String.sub s 0 (back (n - 1))

let selected_config ready = List.nth_opt (config_visible ready) ready.config_sel
let selected_skill ready = List.nth_opt (skills_visible ready) ready.skills_sel

let move_config delta ready =
  match List.length (config_visible ready) with
  | 0 -> ready
  | count ->
      {
        ready with
        config_sel = (((ready.config_sel + delta) mod count) + count) mod count;
      }

let move_skills delta ready =
  match List.length (skills_visible ready) with
  | 0 -> ready
  | count ->
      {
        ready with
        skills_sel = (((ready.skills_sel + delta) mod count) + count) mod count;
      }

let move delta ready =
  match ready.tab with
  | Config -> move_config delta ready
  | Skills -> move_skills delta ready
  | Status | Usage -> ready

let switch_tab dir ready =
  let n = List.length tabs in
  let index_of tab =
    let rec loop i = function
      | [] -> 0
      | t :: _ when t = tab -> i
      | _ :: rest -> loop (i + 1) rest
    in
    loop 0 tabs
  in
  let j = (((index_of ready.tab + dir) mod n) + n) mod n in
  (* Clamp the newly-active tab's selection into its current visible count: its
     list may have shrunk (skills added/removed) while it was inactive, and only
     the active tab is reclamped on a facts refresh. The filter reset above means
     the clamp reads the unfiltered list. *)
  clamp_sel
    { ready with tab = List.nth tabs j; filter = Closed; editing = Browsing }

let next_sort = function
  | By_name -> By_state
  | By_state -> By_cost
  | By_cost -> By_name

let index_in options v =
  match List.find_index (String.equal v) options with Some i -> i | None -> 0

(* Step the enum radio one option and commit it (03-ia §Settings: [←→] commit
   through a [Write_field] the runtime persists). From [Browsing] this opens the
   radio at the current value shifted by [dir]; within [Choosing] it moves from
   the last cursor. The write is live, so the facts reload confirms it. *)
let radio_step dir ready ~field ~options ~current =
  let base =
    match ready.editing with
    | Choosing c when String.equal c.field field -> c.cursor
    | _ -> index_in options current
  in
  match List.length options with
  | 0 -> (Ready ready, Stay)
  | n ->
      let cursor = (((base + dir) mod n) + n) mod n in
      ( Ready { ready with editing = Choosing { field; options; cursor } },
        Write_field { field; value = Some (List.nth options cursor) } )

(* Config, browsing, filter closed. *)
let update_config_keymap ready k =
  let dir_of = function Screen.Left -> -1 | _ -> 1 in
  match k with
  | Screen.Action Screen.Up -> (Ready (move_config (-1) ready), Stay)
  | Screen.Action Screen.Down -> (Ready (move_config 1 ready), Stay)
  | Screen.Action ((Screen.Left | Screen.Right) as a) -> (
      match selected_config ready with
      | Some (_, { Config.value = Config.Enum { current; options }; field; _ })
        ->
          radio_step (dir_of a) ready ~field ~options ~current
      | _ -> (Ready (switch_tab (dir_of a) ready), Stay))
  | Screen.Action Screen.Enter -> (
      match selected_config ready with
      | Some (_, { Config.value = Config.Managed _; _ }) ->
          (Ready ready, Open_model_panel)
      | Some (_, { Config.value = Config.Toggle b; field; _ }) ->
          ( Ready ready,
            Write_field { field; value = Some (string_of_bool (not b)) } )
      | Some (_, { Config.value = Config.Text s; field; _ }) ->
          (Ready { ready with editing = Inputting { field; text = s } }, Stay)
      | Some (_, { Config.value = Config.Enum { current; options }; field; _ })
        ->
          radio_step 1 ready ~field ~options ~current
      | None -> (Ready ready, Stay))
  | _ -> (Ready ready, Stay)

let update_choosing ready (field, options, cursor) k =
  let current = List.nth options cursor in
  match k with
  | Screen.Action Screen.Escape ->
      (Ready { ready with editing = Browsing }, Stay)
  | Screen.Action Screen.Left -> radio_step (-1) ready ~field ~options ~current
  | Screen.Action Screen.Right | Screen.Action Screen.Enter ->
      radio_step 1 ready ~field ~options ~current
  | Screen.Action Screen.Up ->
      (Ready (move_config (-1) { ready with editing = Browsing }), Stay)
  | Screen.Action Screen.Down ->
      (Ready (move_config 1 { ready with editing = Browsing }), Stay)
  | _ -> (Ready ready, Stay)

let update_inputting ready (field, text) k =
  match k with
  | Screen.Action Screen.Escape ->
      (Ready { ready with editing = Browsing }, Stay)
  | Screen.Action Screen.Enter ->
      let v = String.trim text in
      ( Ready { ready with editing = Browsing },
        Write_field
          { field; value = (if String.equal v "" then None else Some v) } )
  | Screen.Action Screen.Backspace ->
      ( Ready { ready with editing = Inputting { field; text = drop_last text } },
        Stay )
  | Screen.Char ch ->
      ( Ready { ready with editing = Inputting { field; text = text ^ ch } },
        Stay )
  | _ -> (Ready ready, Stay)

let update_status_keymap ready k =
  match k with
  | Screen.Char "c" -> (
      match ready.facts.status.Status.session_id with
      | Some id -> (Ready ready, Copy id)
      | None -> (Ready ready, Stay))
  | Screen.Action Screen.Left -> (Ready (switch_tab (-1) ready), Stay)
  | Screen.Action Screen.Right -> (Ready (switch_tab 1 ready), Stay)
  | _ -> (Ready ready, Stay)

let update_usage_keymap ready k =
  match k with
  | Screen.Action Screen.Left -> (Ready (switch_tab (-1) ready), Stay)
  | Screen.Action Screen.Right -> (Ready (switch_tab 1 ready), Stay)
  | _ -> (Ready ready, Stay)

let update_skills_keymap ready k =
  match k with
  | Screen.Action Screen.Up -> (Ready (move_skills (-1) ready), Stay)
  | Screen.Action Screen.Down -> (Ready (move_skills 1 ready), Stay)
  | Screen.Char "t" ->
      (Ready (clamp_sel { ready with sort = next_sort ready.sort }), Stay)
  | Screen.Action Screen.Enter -> (
      match selected_skill ready with
      | Some row -> (Ready ready, Toggle_skill row.Skills.name)
      | None -> (Ready ready, Stay))
  | Screen.Action Screen.Left -> (Ready (switch_tab (-1) ready), Stay)
  | Screen.Action Screen.Right -> (Ready (switch_tab 1 ready), Stay)
  | _ -> (Ready ready, Stay)

(* Filter closed, browsing: the shared chrome keys ([/], [tab], esc) then the
   active tab's keymap. *)
let update_keymap ready k =
  match k with
  | Screen.Char "/" -> (Ready { ready with filter = Open "" }, Stay)
  | Screen.Action Screen.Tab -> (Ready (switch_tab 1 ready), Stay)
  | Screen.Action Screen.Escape -> (Ready ready, Close)
  | _ -> (
      match ready.tab with
      | Config -> update_config_keymap ready k
      | Status -> update_status_keymap ready k
      | Usage -> update_usage_keymap ready k
      | Skills -> update_skills_keymap ready k)

(* Filter open: every printable narrows the active tab's rows; esc closes the
   filter (the ladder's first rung). Enter still fires the row's primary action
   for the toggle-shaped rows; enum and text editing wait until the filter is
   closed. *)
let update_filtering ready q k =
  match k with
  | Screen.Action Screen.Escape -> (Ready { ready with filter = Closed }, Stay)
  | Screen.Action Screen.Backspace ->
      (Ready (clamp_sel { ready with filter = Open (drop_last q) }), Stay)
  | Screen.Char c ->
      (Ready (clamp_sel { ready with filter = Open (q ^ c) }), Stay)
  | Screen.Action Screen.Up -> (Ready (move (-1) ready), Stay)
  | Screen.Action Screen.Down -> (Ready (move 1 ready), Stay)
  | Screen.Action Screen.Enter -> (
      match ready.tab with
      | Config -> (
          match selected_config ready with
          | Some (_, { Config.value = Config.Managed _; _ }) ->
              (Ready ready, Open_model_panel)
          | Some (_, { Config.value = Config.Toggle b; field; _ }) ->
              ( Ready ready,
                Write_field { field; value = Some (string_of_bool (not b)) } )
          | _ -> (Ready ready, Stay))
      | Skills -> (
          match selected_skill ready with
          | Some row -> (Ready ready, Toggle_skill row.Skills.name)
          | None -> (Ready ready, Stay))
      | Status | Usage -> (Ready ready, Stay))
  | _ -> (Ready ready, Stay)

let update (Key k) t =
  match t with
  | Loading _ | Load_error _ -> (
      match k with Screen.Action Screen.Escape -> (t, Close) | _ -> (t, Stay))
  | Ready ready -> (
      match ready.editing with
      | Choosing { field; options; cursor } ->
          update_choosing ready (field, options, cursor) k
      | Inputting { field; text } -> update_inputting ready (field, text) k
      | Browsing -> (
          match ready.filter with
          | Open q -> update_filtering ready q k
          | Closed -> update_keymap ready k))

(* Rendering. *)

let default_style = Ansi.Style.default
let cursor_cols = 2

let pad_right w s =
  let n = String.length s in
  if n >= w then s else s ^ String.make (w - n) ' '

let blank_row = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let muted_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted s ]

let error_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.error (Theme.problem ^ s) ]

(* Thousands-grouped integer, as the old settings panel formats token counts. *)
let format_int value =
  let s = string_of_int value in
  let len = String.length s in
  if len <= 3 then s
  else
    let buf = Buffer.create (len + (len / 3)) in
    String.iteri
      (fun i c ->
        if i > 0 && (len - i) mod 3 = 0 then Buffer.add_char buf ',';
        Buffer.add_char buf c)
      s;
    Buffer.contents buf

let value_text (v : Config.value) =
  match v with
  | Config.Enum { current = ""; _ } -> "—"
  | Config.Enum { current; _ } -> current
  | Config.Toggle b -> string_of_bool b
  | Config.Text "" -> "—"
  | Config.Text s -> s
  | Config.Managed s -> s

let tab_label = function
  | Config -> "config"
  | Status -> "status"
  | Usage -> "usage"
  | Skills -> "skills"

(* The tab row under the rule: the four labels, selected accent and the rest
   muted, [ · ]-joined (03-ia §Settings). *)
let tab_row active =
  let pieces =
    List.concat
      (List.mapi
         (fun i tab ->
           let style = if tab = active then Theme.accent else Theme.muted in
           let sep = if i = 0 then [] else [ seg Theme.faint " · " ] in
           sep @ [ seg style (tab_label tab) ])
         tabs)
  in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    pieces

let group_header title =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted title ]

(* The inline enum radio: each option, the chosen one marked [●] in accent, the
   rest muted, two spaces between (03-ia §Settings, glyph list). *)
let radio_view ~options ~cursor =
  List.concat
    (List.mapi
       (fun i opt ->
         let sep = if i = 0 then [] else [ seg Theme.faint "  " ] in
         if i = cursor then sep @ [ seg Theme.accent ("● " ^ opt) ]
         else sep @ [ seg Theme.muted opt ])
       options)

(* One config row: the cursor, the label column, then the value — or its inline
   radio/input — and any advisory danger caution. The selected row wears the
   accent cursor, label, and value; an unselected value renders muted at its
   default and default-fg once changed (03-ia §Settings). *)
let config_row_view ~label_w ~selected ~editing (row : Config.row) =
  let cursor =
    if selected then seg Theme.accent Theme.cursor else seg default_style "  "
  in
  let label_style = if selected then Theme.accent else default_style in
  let label =
    cell label_w (seg label_style (pad_right label_w row.Config.label))
  in
  let value_children =
    match (selected, editing, row.Config.value) with
    | true, Choosing { options; cursor; _ }, Config.Enum _ ->
        radio_view ~options ~cursor
    | true, Inputting { text; _ }, Config.Text _ ->
        [ seg Theme.accent (text ^ "▏") ]
    | _ -> (
        let vstyle =
          if selected then Theme.accent
          else if row.Config.is_default then Theme.muted
          else default_style
        in
        let base = [ seg vstyle (value_text row.Config.value) ] in
        match row.Config.danger with
        | Some note -> base @ [ seg Theme.warning ("  — " ^ note) ]
        | None -> base)
  in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    (cell cursor_cols cursor :: label :: value_children)

(* Window the visible rows around the selection. Config and skills both use this
   selection window; config separately chooses the largest item budget whose
   rendered headers, gaps, rows, and overflow marker fit the visual budget. *)
let window ~budget ~selected rows =
  let n = List.length rows in
  if n <= budget then (rows, 0)
  else
    let start = if selected < budget then 0 else selected - budget + 1 in
    let start = min start (n - budget) in
    let shown =
      List.filteri (fun i _ -> i >= start && i < start + budget) rows
    in
    (shown, n - start - budget)

let widest_config_label facts =
  List.fold_left
    (fun w (_, (row : Config.row)) -> max w (String.length row.Config.label))
    0 (config_flat facts)

let config_window_cost shown =
  let _, cost =
    List.fold_left
      (fun (previous, cost) (title, _) ->
        let chrome =
          match previous with
          | None -> 1
          | Some previous when String.equal previous title -> 0
          | Some _ -> 2
        in
        (Some title, cost + chrome + 1))
      (None, 0) shown
  in
  cost

(* Choose the largest slice the existing selection window can show while
   charging every visual row it will render. The one tail marker summarizes all
   hidden settings, including rows before a window that has followed the
   selection downward. *)
let config_window ~budget ~selected visible =
  let count = List.length visible in
  let rec choose item_budget best =
    if item_budget > count then best
    else
      let shown, after = window ~budget:item_budget ~selected visible in
      let shown_count = List.length shown in
      let offset = count - shown_count - after in
      let hidden = count - shown_count in
      let cost = config_window_cost shown + if hidden > 0 then 1 else 0 in
      let best =
        if cost <= budget then Some (shown, hidden, offset) else best
      in
      choose (item_budget + 1) best
  in
  match choose 1 None with Some result -> result | None -> ([], count, 0)

let config_body ~budget ready =
  match config_visible ready with
  | [] -> [ muted_line "No matching settings." ]
  | visible ->
      let shown, hidden, offset =
        config_window ~budget ~selected:ready.config_sel visible
      in
      let label_w = 2 + widest_config_label ready.facts in
      let _, elements =
        List.fold_left
          (fun (i, acc) (title, row) ->
            let prev_title =
              if i = 0 then None
              else Some (fst (List.nth visible (offset + i - 1)))
            in
            let header =
              if Some title = prev_title then []
              else if i = 0 then [ group_header title ]
              else [ blank_row; group_header title ]
            in
            let is_selected = offset + i = ready.config_sel in
            let line =
              config_row_view ~label_w ~selected:is_selected
                ~editing:ready.editing row
            in
            (i + 1, acc @ header @ [ line ]))
          (0, []) shown
      in
      let tail =
        if hidden > 0 && budget > 0 then
          [ muted_line (Printf.sprintf "… +%d more" hidden) ]
        else []
      in
      elements @ tail

(* A two-column read-only row (status and usage): a padded label, then the value
   pre-truncated to the remaining width so it never wraps under the label. *)
let two_col ~width ~label_w ?(value_style = Theme.muted) label value =
  let value_w = max 4 (width - 4 - label_w) in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [
      seg default_style (pad_right label_w label);
      seg value_style (truncate_tail ~width:value_w value);
    ]

let status_body ~width ready =
  let rows = ready.facts.status.Status.rows in
  let label_w =
    2
    + List.fold_left
        (fun w (r : Status.fact) -> max w (String.length r.Status.label))
        0 rows
  in
  List.map
    (fun (r : Status.fact) ->
      two_col ~width ~label_w r.Status.label r.Status.value)
    rows

let usage_body ~width ready =
  let u = ready.facts.usage in
  if not u.Usage.has_turns then [ muted_line "No turns yet in this session." ]
  else
    let pairs =
      ("model", u.Usage.model)
      :: List.map
           (fun (l : Usage.lane) -> (l.Usage.label, format_int l.Usage.tokens))
           u.Usage.lanes
      @ [ ("cost", u.Usage.cost) ]
    in
    let label_w =
      2 + List.fold_left (fun w (name, _) -> max w (String.length name)) 0 pairs
    in
    List.map (fun (name, value) -> two_col ~width ~label_w name value) pairs
    @ [ blank_row; muted_line u.Usage.scope ]

let skills_row_view ~width ~selected (row : Skills.row) =
  let inner = max 1 (width - 4) in
  let cost_s =
    if row.Skills.cost > 0 then
      Printf.sprintf "~%s tok" (format_int row.Skills.cost)
    else "—"
  in
  let state_w = 10 and source_w = 10 in
  let cost_w = max 8 (String.length cost_s) in
  let name_w = max 8 (inner - cursor_cols - state_w - source_w - cost_w) in
  let name_style =
    if selected then Theme.accent
    else if row.Skills.enabled then default_style
    else Theme.muted
  in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [
      cell cursor_cols
        (if selected then seg Theme.accent Theme.cursor
         else seg default_style "  ");
      cell name_w (seg name_style (truncate_tail ~width:name_w row.Skills.name));
      cell state_w (seg Theme.muted (pad_right state_w row.Skills.state));
      cell source_w (seg Theme.muted (pad_right source_w row.Skills.source));
      cell cost_w (seg Theme.muted cost_s);
    ]

let skills_body ~width ~rows ready =
  if not ready.facts.skills.Skills.available then
    [ muted_line "Skills are disabled." ]
  else
    match skills_visible ready with
    | [] -> (
        match ready.facts.skills.Skills.rows with
        | [] -> [ muted_line "No skills discovered." ]
        | _ -> [ muted_line "No matching skills." ])
    | visible ->
        let budget = max 3 (rows - 9) in
        let shown, older = window ~budget ~selected:ready.skills_sel visible in
        let offset = List.length visible - List.length shown - older in
        let _, elements =
          List.fold_left
            (fun (i, acc) (row : Skills.row) ->
              let is_selected = offset + i = ready.skills_sel in
              let line = skills_row_view ~width ~selected:is_selected row in
              let detail =
                if is_selected then
                  match row.Skills.description with
                  | Some d when String.trim d <> "" ->
                      [
                        box ~flex_shrink:0. ~padding:(padding_lrtb 4 2 0 0)
                          ~size:{ width = pct 100; height = px 1 }
                          [
                            seg Theme.faint
                              (truncate_tail ~width:(max 1 (width - 6)) d);
                          ];
                      ]
                  | _ -> []
                else []
              in
              (i + 1, acc @ (line :: detail)))
            (0, []) shown
        in
        let tail =
          if older > 0 then [ muted_line (Printf.sprintf "… +%d more" older) ]
          else []
        in
        elements @ tail

let body ~width ~rows ready =
  match ready.tab with
  | Config ->
      (* Screen chrome costs four rows with a closed filter and five with an
         open one; the tab row and its following blank cost two more. *)
      let chrome = match ready.filter with Closed -> 6 | Open _ -> 7 in
      config_body ~budget:(max 0 (rows - chrome)) ready
  | Status -> status_body ~width ready
  | Usage -> usage_body ~width ready
  | Skills -> skills_body ~width ~rows ready

let content ~width ~rows t =
  match t with
  | Loading { tab } ->
      [ tab_row tab; blank_row; muted_line "⠋ loading settings…" ]
  | Load_error message -> [ error_line message ]
  | Ready ready -> tab_row ready.tab :: blank_row :: body ~width ~rows ready

let fact t =
  match t with
  | Ready ready -> (
      match ready.tab with
      | Config -> ready.facts.config.Config.sources
      | Skills -> Printf.sprintf "~%d tok" ready.facts.skills.Skills.budget
      | Status | Usage -> "")
  | Loading _ | Load_error _ -> ""

let active_visible_count ready =
  match ready.tab with
  | Config -> List.length (config_visible ready)
  | Skills -> List.length (skills_visible ready)
  | Status -> List.length ready.facts.status.Status.rows
  | Usage -> List.length ready.facts.usage.Usage.lanes

let filter_line t =
  match t with
  | Ready ready -> (
      match ready.filter with
      | Closed -> None
      | Open q ->
          Some { Screen.query = q; matches = active_visible_count ready })
  | Loading _ | Load_error _ -> None

let hint t =
  match t with
  | Loading _ | Load_error _ -> [ "esc back" ]
  | Ready ready -> (
      match ready.editing with
      | Choosing _ -> [ "←→ choose"; "esc close" ]
      | Inputting _ -> [ "↵ save"; "esc cancel" ]
      | Browsing -> (
          match ready.filter with
          | Open _ -> [ "↑↓ select"; "esc clear filter" ]
          | Closed -> (
              match ready.tab with
              | Config ->
                  [
                    "↵ edit"; "↑↓ move"; "←→ tab/value"; "/ filter"; "esc back";
                  ]
              | Status -> [ "c copy id"; "←→ tab"; "esc back" ]
              | Usage -> [ "←→ tab"; "esc back" ]
              | Skills ->
                  [
                    "↵ toggle";
                    "t sort";
                    "↑↓ move";
                    "←→ tab";
                    "/ filter";
                    "esc back";
                  ])))

let view ~frame ~width ~rows t =
  Screen.view ~frame ~name:"settings" ~fact:(fact t) ~filter:(filter_line t)
    ~hint:(hint t) ~width ~rows ~content:(content ~width ~rows t)
