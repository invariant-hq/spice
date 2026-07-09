(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type model = {
  selector : string;
  name : string;
  provider_title : string;
  detail : string;
  locked : bool;
  is_current : bool;
  supported_reasoning : Spice_llm.Request.Options.Reasoning_effort.t list;
  default_reasoning : Spice_llm.Request.Options.Reasoning_effort.t option;
  warning : string option;
  search_key : string;
}

type facts = {
  models : model list;
  reasoning : Spice_llm.Request.Options.Reasoning_effort.t option;
}

type ready = {
  facts : facts;
  filter : string;
  selected : int;
  effort : Spice_llm.Request.Options.Reasoning_effort.t option;
      (** The live effort [←]/[→] adjusts, seeded from {!facts.reasoning}. *)
}

type t = Loading | Failed of string | Ready of ready
type msg = Key of Panel.key

type event =
  | Stay
  | Close
  | Select of {
      selector : string;
      effort : Spice_llm.Request.Options.Reasoning_effort.t option;
    }
  | Login_required of string

let loading = Loading

(* One selectable slot: a catalog model, or — hoisted to the top while the filter
   is empty — the current model shown as the "Default (recommended)" alias. The
   digit jump-pick and the cursor index this list; the group headers between rows
   are chrome the view interleaves, not slots. *)
type slot = { model : model; alias : bool }

(* Case-insensitive substring match, byte-wise over the lowercased search key —
   the same narrowing the sessions panel uses. *)
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

let current_model models = List.find_opt (fun m -> m.is_current) models

let visible_models ready =
  if String.equal ready.filter "" then ready.facts.models
  else
    let needle = String.lowercase_ascii ready.filter in
    List.filter
      (fun m -> contains ~needle (String.lowercase_ascii m.search_key))
      ready.facts.models

(* The slots the panel navigates: the "Default (recommended)" alias for the
   current model heads an empty filter (05-overlays-pickers.md §Model picker),
   then every filtered model. Once the user types, the alias disappears. *)
let slots ready =
  let models = visible_models ready in
  let alias =
    if String.equal ready.filter "" then
      match current_model models with
      | Some model -> [ { model; alias = true } ]
      | None -> []
    else []
  in
  alias @ List.map (fun model -> { model; alias = false }) models

let has_alias ready =
  match slots ready with { alias = true; _ } :: _ -> true | _ -> false

let clamp ready =
  match List.length (slots ready) with
  | 0 -> { ready with selected = 0 }
  | count -> { ready with selected = max 0 (min ready.selected (count - 1)) }

(* The opening selection lands on the hoisted default (the current model), else
   the first unlocked model — a locked row is never the initially-highlighted one
   (05-overlays-pickers.md §Locked providers). *)
let initial_selection slots =
  match slots with
  | { alias = true; _ } :: _ -> 0
  | _ ->
      let rec loop i = function
        | [] -> 0
        | slot :: rest -> if slot.model.locked then loop (i + 1) rest else i
      in
      loop 0 slots

let loaded facts t =
  match t with
  | Loading | Failed _ ->
      let ready =
        { facts; filter = ""; selected = 0; effort = facts.reasoning }
      in
      Ready { ready with selected = initial_selection (slots ready) }
  | Ready ready -> Ready (clamp { ready with facts })

let failed message = function
  | Ready ready when ready.facts.models <> [] -> Ready ready
  | Loading | Failed _ | Ready _ -> Failed message

let key ev =
  match Panel.classify ev with
  | Panel.Action Panel.Other -> None
  | k -> Some (Key k)

let move delta ready =
  match List.length (slots ready) with
  | 0 -> ready
  | count ->
      {
        ready with
        selected = (((ready.selected + delta) mod count) + count) mod count;
      }

(* The effort a pick persists for a model: the panel's live effort when the model
   supports it, else [None] (follow the model default). Selecting the default
   level records [None] rather than pinning it (see [adjust]), so "follow the
   default" survives a later change to the model's default. *)
let selected_effort ready model =
  match ready.effort with
  | Some effort when List.mem effort model.supported_reasoning -> Some effort
  | Some _ | None -> None

(* The concrete effort level the panel shows for a model — the exact value the
   effort line renders and the [←]/[→] index walks: the live override when the
   model supports it, else the model default, else [Disabled] ("No effort"). *)
let current_level ready model =
  match selected_effort ready model with
  | Some effort -> effort
  | None -> (
      match model.default_reasoning with
      | Some default -> default
      | None -> Spice_llm.Request.Options.Reasoning_effort.Disabled)

let index_of eq x xs =
  let rec loop i = function
    | [] -> 0
    | y :: rest -> if eq x y then i else loop (i + 1) rest
  in
  loop 0 xs

(* [←]/[→] walk the supported levels in order and wrap at the ends. Landing on
   the model's default level records [None] (follow-default) rather than an
   explicit pin, so the default stop reads [(default)] and never duplicates a
   separate "provider default" row. *)
let adjust delta ready =
  match List.nth_opt (slots ready) ready.selected with
  | None -> ready
  | Some { model; _ } -> (
      match model.supported_reasoning with
      | [] -> ready
      | supported ->
          let count = List.length supported in
          let current = current_level ready model in
          let index = index_of ( = ) current supported in
          let index = (((index + delta) mod count) + count) mod count in
          let level = List.nth supported index in
          let effort =
            if Option.equal ( = ) model.default_reasoning (Some level) then None
            else Some level
          in
          { ready with effort })

(* The provider id a locked-row login reroute pre-selects, taken from the
   canonical [provider/model] selector — the value [/login <provider>] resolves
   against (09-auth.md). *)
let provider_id_of_selector selector =
  match String.index_opt selector '/' with
  | Some i -> String.sub selector 0 i
  | None -> selector

let pick ready =
  match List.nth_opt (slots ready) ready.selected with
  | None -> (Ready ready, Stay)
  | Some { model; _ } ->
      if model.locked then
        (Ready ready, Login_required (provider_id_of_selector model.selector))
      else
        ( Ready ready,
          Select
            { selector = model.selector; effort = selected_effort ready model }
        )

(* A digit jump-picks the nth visible slot (1-indexed) while the filter is empty,
   moving the selection without confirming — the effort is part of a model pick,
   so a bare digit must not persist one. Out of range is a no-op. *)
let jump ready d =
  if d < 1 then (Ready ready, Stay)
  else
    match List.nth_opt (slots ready) (d - 1) with
    | Some _ -> (Ready { ready with selected = d - 1 }, Stay)
    | None -> (Ready ready, Stay)

(* Drop the last UTF-8 scalar of the filter, walking back over continuation bytes
   so a multibyte narrow deletes whole. *)
let drop_last s =
  let n = String.length s in
  if n = 0 then s
  else
    let rec back i =
      if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then back (i - 1) else i
    in
    String.sub s 0 (back (n - 1))

let narrow ready appended =
  ( Ready (clamp { ready with filter = ready.filter ^ appended; selected = 0 }),
    Stay )

let update (Key k) t =
  match t with
  | Loading | Failed _ -> (
      match k with Panel.Action Panel.Escape -> (t, Close) | _ -> (t, Stay))
  | Ready ready -> (
      match k with
      | Panel.Action Panel.Escape -> (Ready ready, Close)
      | Panel.Action Panel.Enter -> pick ready
      | Panel.Action Panel.Up -> (Ready (move (-1) ready), Stay)
      | Panel.Action Panel.Down -> (Ready (move 1 ready), Stay)
      | Panel.Action Panel.Left -> (Ready (adjust (-1) ready), Stay)
      | Panel.Action Panel.Right -> (Ready (adjust 1 ready), Stay)
      | Panel.Action Panel.Backspace ->
          ( Ready
              (clamp
                 { ready with filter = drop_last ready.filter; selected = 0 }),
            Stay )
      | Panel.Printable s -> narrow ready s
      | Panel.Digit d ->
          if String.equal ready.filter "" then jump ready d
          else narrow ready (string_of_int d)
      | Panel.Action (Panel.Tab | Panel.Ctrl_d | Panel.Other) ->
          (Ready ready, Stay))

(* Glyphs the panel needs that {!Theme} does not yet carry (contract gap reported
   upstream): the current-item check and the reasoning-effort intensity ramp
   (05-overlays-pickers.md §Model picker) — ○ minimal/low, ◐ medium, ● high,
   ◉ extra-high/max. *)
let check = "✓"
let effort_low = "○"
let effort_medium = "◐"
let effort_high = "●"
let effort_max = "◉"
let default_style = Ansi.Style.default
let hidden = { x = Overflow.Hidden; y = Overflow.Hidden }
let blank_row = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let muted_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted s ]

let error_line s =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.error (Theme.problem ^ s) ]

let group_header title =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.muted ("  " ^ title) ]

(* Display-column truncation over UTF-8: every glyph the rows draw ([·], […],
   ASCII) is one column wide, so a codepoint count is the column count. Truncating
   in OCaml rather than with [~truncate:true] avoids the text-surface
   re-measurement quirk (doc/plans/tui-next.md §Rules), so a filtered re-layout
   never drops a widened tail. *)
let utf8_char_len c =
  let b = Char.code c in
  if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4

let column_count s =
  let n = String.length s in
  let rec loop i acc =
    if i >= n then acc else loop (i + utf8_char_len s.[i]) (acc + 1)
  in
  loop 0 0

let truncate_cols ~cols s =
  if cols <= 0 then ""
  else if column_count s <= cols then s
  else
    let rec take i c =
      if i >= String.length s || c >= cols - 1 then i
      else take (i + utf8_char_len s.[i]) (c + 1)
    in
    String.sub s 0 (take 0 0) ^ "…"

let label_cap = 24
let cursor_cols = 2

(* One model row (shared list anatomy, 05-overlays-pickers.md rules 4-6): the
   cursor at column 1, the label (accent when selected, muted for a locked row,
   default otherwise), a right-aligned muted detail, then the fixed trailing
   affordance — the current model's [✓] or a locked provider's faint [log in to
   use], which never truncates. The detail is pre-truncated in OCaml so the flex
   spacer always keeps a gap and nothing overflows. The row box carries the hover
   tint so the whole line reads as the selection. *)
let model_row ~width ~selected ~mark_current slot =
  let model = slot.model in
  let label = if slot.alias then "Default (recommended)" else model.name in
  let label = truncate_cols ~cols:label_cap label in
  let label_style =
    if model.locked then Theme.muted
    else if selected then Theme.accent
    else default_style
  in
  (* The alias names the concrete model it stands for (05-overlays-pickers.md
     §Default row); a plain row shows only its own detail. *)
  let base_detail =
    if slot.alias && not (String.equal model.detail "") then
      model.name ^ Theme.separator ^ model.detail
    else if slot.alias then model.name
    else model.detail
  in
  let is_current =
    (mark_current || slot.alias) && model.is_current && not model.locked
  in
  let trailing, trailing_cols =
    if model.locked then
      ([ seg Theme.faint (Theme.separator ^ "log in to use") ], 15)
    else if is_current then ([ seg Theme.success (" " ^ check) ], 2)
    else ([], 0)
  in
  let inner = max 1 (width - 4) in
  let detail_cols =
    max 0 (inner - cursor_cols - column_count label - trailing_cols - 2)
  in
  let detail = truncate_cols ~cols:detail_cols base_detail in
  let background = if selected then Some Theme.color_hover_bg else None in
  box ?background ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~overflow:hidden ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    ([
       (if selected then seg Theme.accent Theme.cursor
        else seg default_style "  ");
       seg label_style label;
       box ~flex_grow:1. ~flex_shrink:1. [];
       seg Theme.muted detail;
     ]
    @ trailing)

(* The effort-line glyph reads the level's intensity; [accent] once an effort is
   set, [muted] at the low end. *)
let effort_glyph = function
  | Spice_llm.Request.Options.Reasoning_effort.Disabled
  | Spice_llm.Request.Options.Reasoning_effort.Minimal
  | Spice_llm.Request.Options.Reasoning_effort.Low ->
      effort_low
  | Spice_llm.Request.Options.Reasoning_effort.Medium -> effort_medium
  | Spice_llm.Request.Options.Reasoning_effort.High -> effort_high
  | Spice_llm.Request.Options.Reasoning_effort.Extra_high
  | Spice_llm.Request.Options.Reasoning_effort.Max ->
      effort_max

let effort_word = function
  | Spice_llm.Request.Options.Reasoning_effort.Disabled -> "No"
  | Spice_llm.Request.Options.Reasoning_effort.Minimal -> "Minimal"
  | Spice_llm.Request.Options.Reasoning_effort.Low -> "Low"
  | Spice_llm.Request.Options.Reasoning_effort.Medium -> "Medium"
  | Spice_llm.Request.Options.Reasoning_effort.High -> "High"
  | Spice_llm.Request.Options.Reasoning_effort.Extra_high -> "Extra high"
  | Spice_llm.Request.Options.Reasoning_effort.Max -> "Max"

let top_tier = function
  | Spice_llm.Request.Options.Reasoning_effort.Extra_high
  | Spice_llm.Request.Options.Reasoning_effort.Max ->
      true
  | Spice_llm.Request.Options.Reasoning_effort.Disabled
  | Spice_llm.Request.Options.Reasoning_effort.Minimal
  | Spice_llm.Request.Options.Reasoning_effort.Low
  | Spice_llm.Request.Options.Reasoning_effort.Medium
  | Spice_llm.Request.Options.Reasoning_effort.High ->
      false

(* The inline reasoning-effort line for the highlighted model (05-overlays-pickers.md
   §Model picker, following Claude Code): the intensity glyph, the level word, an
   optional [(default)] tag, then [← → to adjust]. A preview/deprecated model or a
   top-tier effort replaces the adjust affordance with a single [⚠] caution. A
   model that takes no effort shows a muted "Effort not supported" line instead. *)
let effort_line ready model =
  match model.supported_reasoning with
  | [] ->
      box ~flex_shrink:0. ~overflow:hidden ~padding:(padding_lrtb 2 2 0 0)
        ~size:{ width = pct 100; height = px 1 }
        [
          seg Theme.muted
            (effort_low ^ " Effort not supported for " ^ model.name);
        ]
  | _ ->
      let effort = current_level ready model in
      let is_default =
        Option.equal ( = ) model.default_reasoning (Some effort)
      in
      let glyph = effort_glyph effort in
      let glyph_style =
        if String.equal glyph effort_low then Theme.muted else Theme.accent
      in
      let suffix = if is_default then " (default)" else "" in
      let label = effort_word effort ^ " effort" ^ suffix in
      let caution =
        match model.warning with
        | Some w -> Some w
        | None -> if top_tier effort then Some "highest tier" else None
      in
      let tail =
        match caution with
        | Some w -> seg Theme.warning ("  ⚠ " ^ w)
        | None -> seg Theme.faint "  ← → to adjust"
      in
      box ~flex_shrink:0. ~overflow:hidden ~padding:(padding_lrtb 2 2 0 0)
        ~size:{ width = pct 100; height = px 1 }
        [
          seg glyph_style (glyph ^ " ");
          seg default_style label;
          tail;
          box ~flex_grow:1. [];
        ]

(* A centered window keeps the selection visible without the list growing
   unbounded — 03-ia open question 1, settled for the first tall panel. The panel
   is bottom-anchored under the home stage (or the chat transcript), so the list
   is capped tight enough that the boundary, effort line, and hint always fit
   above the stage at 24 rows (like the sessions panel's four rows); the stage or
   transcript above never fully disappears. [↑ N]/[↓ N more] mark the seams. *)
let window_limit rows = max 3 (min 8 (rows - 20))

let window ~limit ~selected ~count =
  if count <= limit then (0, count)
  else
    let start = selected - (limit / 2) in
    let start = max 0 (min start (count - limit)) in
    (start, limit)

(* Render the slots into their display rows, interleaving the muted provider
   headers (a blank line above each group after the first) and tracking the
   selected slot's row so the window can centre on it. *)
let list_rows ~width ready =
  let mark_current = not (has_alias ready) in
  let rec loop y prev group_started selected_y acc = function
    | [] -> (List.rev acc, selected_y)
    | (index, slot) :: rest ->
        let headers =
          if slot.alias then []
          else if
            Option.equal String.equal prev (Some slot.model.provider_title)
          then []
          else
            let blank = if group_started then [ blank_row ] else [] in
            blank @ [ group_header slot.model.provider_title ]
        in
        let prev =
          if slot.alias then prev else Some slot.model.provider_title
        in
        let group_started = group_started || not slot.alias in
        let y = y + List.length headers in
        let selected_y =
          if index = ready.selected then Some y else selected_y
        in
        let row =
          model_row ~width ~selected:(index = ready.selected) ~mark_current slot
        in
        loop (y + 1) prev group_started selected_y
          (row :: List.rev_append headers acc)
          rest
  in
  slots ready
  |> List.mapi (fun index slot -> (index, slot))
  |> loop 0 None false None []

let list_block ~width ~rows ready =
  let rendered, selected_y = list_rows ~width ready in
  let count = List.length rendered in
  let limit = window_limit rows in
  let start, length =
    window ~limit ~selected:(Option.value selected_y ~default:0) ~count
  in
  let visible =
    rendered |> List.filteri (fun i _ -> i >= start && i < start + length)
  in
  let above =
    if start > 0 then [ muted_line ("↑ " ^ string_of_int start ^ " more") ]
    else []
  in
  let below =
    if start + length < count then
      [ muted_line ("↓ " ^ string_of_int (count - start - length) ^ " more") ]
    else []
  in
  above @ visible @ below

let content ~width ~rows t =
  match t with
  | Loading -> [ muted_line "⠋ loading models…" ]
  | Failed message -> [ error_line message ]
  | Ready ready -> (
      match slots ready with
      | [] ->
          if String.equal ready.filter "" then
            [ muted_line "No models available." ]
          else [ muted_line "No matching models." ]
      | slots -> (
          let selected =
            List.nth_opt slots
              (max 0 (min ready.selected (List.length slots - 1)))
          in
          list_block ~width ~rows ready
          @
          match selected with
          | Some { model; _ } -> [ blank_row; effort_line ready model ]
          | None -> []))

let view ~frame ~width ~rows t =
  let filter =
    match t with Loading | Failed _ -> "" | Ready ready -> ready.filter
  in
  Panel.view ~frame ~name:"model" ~filter ~width
    ~hint:
      [
        "↵ set default"; "←→ effort"; "type to filter"; "↑↓ select"; "esc close";
      ]
    ~content:(content ~width ~rows t)
