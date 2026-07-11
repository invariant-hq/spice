(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type verb =
  | Read
  | List
  | Search
  | Update
  | Create
  | Shell
  | Eval
  | Fetch
  | Web_search
  | Task
  | Todo
  | Dune
  | Diagnostics
  | Outline
  | Type
  | Definition
  | References
  | Skill
  | Plan
  | Goal
  | Message
  | Cancel
  | Wait
  | Question
  | Other of string

type dot = Running | Ok | Failed | Warned | Awaiting
type diff_file = { label : string; patch : Mosaic.Diff.Patch.t }
type todo_status = Done | Active | Pending
type todo_item = { status : todo_status; content : string }

type detail =
  | Summary
  | Diff of diff_file list
  | Preview of { lines : string list; overflow : int }
  | Todos of todo_item list

type t = {
  verb : verb;
  argument : string;
  dot : dot;
  summary : string;
  facts : string list;
  disclosable : bool;
  detail : detail;
}

let label = function
  | Read -> "Read"
  | List -> "List"
  | Search -> "Search"
  | Update -> "Update"
  | Create -> "Create"
  | Shell -> "Shell"
  | Eval -> "Eval"
  | Fetch -> "Fetch"
  | Web_search -> "Web Search"
  | Task -> "Task"
  | Todo -> "Todo"
  | Dune -> "Dune"
  | Diagnostics -> "Diagnostics"
  | Outline -> "Outline"
  | Type -> "Type"
  | Definition -> "Definition"
  | References -> "References"
  | Skill -> "Skill"
  | Plan -> "Plan"
  | Goal -> "Goal"
  | Message -> "Message"
  | Cancel -> "Cancel"
  | Wait -> "Wait"
  | Question -> "Question"
  (* The fallback for a tool with no 02-tools verb: its own registered name,
     first letter capitalized so a raw [ask_user] reads as [Ask_user] rather
     than lowercase. *)
  | Other name -> String.capitalize_ascii name

(* Outcome-colored dots (02-tools.md §Header and result grammar, revised
   2026-07-07): a settled tool call shows its verdict at a glance — success
   green, failure red, warnings-only yellow. The green is unbolded so a wall of
   passed calls stays quiet next to the bold error dot of a failure. *)
let dot_success = Ansi.Style.make ~fg:Theme.color_success ()

let dot_style = function
  | Running -> Theme.running
  | Ok -> dot_success
  | Failed -> Theme.error
  | Warned -> Theme.warning
  | Awaiting -> Theme.muted

(* Pre-truncate to at most [max] columns with a trailing [ … ], never splitting a
   UTF-8 scalar — the house rule for one-line text, since Mosaic flex-truncation
   measures at the text's prior layout width and drops the tail with no ellipsis
   (02-tools.md §Truncation; the flex-truncate quirk). The budget is in bytes, a
   conservative proxy for columns: exact for ASCII, trims a touch early for
   multibyte, and never overflows. *)
let clip ~max s =
  if String.length s <= max then s
  else
    let cut = ref (Stdlib.max 0 (max - 3)) in
    while !cut > 0 && Char.code s.[!cut] land 0xC0 = 0x80 do
      decr cut
    done;
    String.sub s 0 !cut ^ "…"

(* Pre-truncate a header argument to the columns the dot, verb label, and parens
   leave, so the [ … ] and the closing [)] always render. Callers that hold the
   width pre-truncate through this before {!header}; the header itself keeps a
   flex fallback for the one caller without a width (the shell running header). *)
let header_argument ~width ~verb argument =
  if argument = "" then argument
  else
    clip ~max:(Stdlib.max 4 (width - (String.length (label verb) + 4))) argument

let header verb ~argument ~dot =
  let name = seg Theme.bold (label verb) in
  let arg =
    if argument = "" then []
    else
      [
        seg Ansi.Style.default "(";
        (* A width-holding caller pre-truncates [argument] via {!header_argument},
           so this fits and the flex shrink never clips; the one caller without a
           width (the shell running header) still flex-clips. *)
        text ~style:Ansi.Style.default ~wrap:`None ~flex_shrink:1. argument;
        seg Ansi.Style.default ")";
      ]
  in
  box ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = px 1 }
    (seg (dot_style dot) (Theme.tool ^ " ") :: name :: arg)

let result ?(disclosable = false) ~summary ~facts () =
  let sep = seg Theme.muted Theme.separator in
  let facts = List.concat_map (fun f -> [ sep; seg Theme.muted f ]) facts in
  (* [disclosable] names hidden detail, but no glyph marks it: nothing can
     expand a settled block today, and a [▸] would advertise an expansion
     that does not exist. The marker returns with the disclosure mechanism. *)
  let _ = disclosable in
  let disc = [] in
  (* The summary wraps with a hanging indent under the [⎿] column so a long
     error message is never lost off the terminal edge (02-tools.md §Shell /
     §Header) — the same fixed-gutter + wrapping-body shape as a failure notice.
     The facts and disclosure ride the flow after the summary. *)
  box ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = auto }
    [
      seg Theme.muted ("  " ^ Theme.gutter ^ "  ");
      box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
        [
          box ~flex_direction:Flex_direction.Row
            ~size:{ width = pct 100; height = auto }
            (text ~style:Theme.muted ~wrap:`Word ~flex_shrink:1. summary
            :: (facts @ disc));
        ];
    ]

(* ── The shared truncation law (02-tools.md §Truncation) ──────────────────── *)

let preview ~take ~cap lines =
  let total = List.length lines in
  if total <= cap then Preview { lines; overflow = 0 }
  else
    (* One line over the cap would hide behind a [… +1 lines] row that costs
       the same height as the line itself — so show it instead (02-tools.md
       §Truncation). *)
    let shown = if total = cap + 1 then cap + 1 else cap in
    let lines =
      match take with
      | `First -> List.take shown lines
      | `Last -> List.drop (total - shown) lines
    in
    Preview { lines; overflow = total - shown }

(* ── Views ────────────────────────────────────────────────────────────────── *)

(* Detail hangs under the result: text previews and todo rows align one column
   past the [⎿  summary] text (02-tools.md mockups); a diff sits a touch left so
   its own line-number gutter has room. *)
let preview_pad = padding_lrtb 6 0 0 0
let diff_pad = padding_lrtb 4 0 0 0

let more_row count =
  (* The overflow marker (02-tools.md §File edits / §Shell) states the elision
     and nothing more: no [▸], because nothing can disclose the hidden lines
     today. The affordance arrives with the disclosure mechanism. *)
  box ~flex_direction:Flex_direction.Row ~padding:preview_pad
    ~size:{ width = pct 100; height = px 1 }
    [ seg Theme.faint (Printf.sprintf "… +%d lines" count) ]

let preview_view ~width lines overflow =
  (* Preview rows indent 6 columns and never wrap, so a long content line clips
     silently without this pre-truncation. *)
  let budget = Stdlib.max 4 (width - 6) in
  let line l =
    box ~flex_direction:Flex_direction.Row ~padding:preview_pad
      ~size:{ width = pct 100; height = px 1 }
      [ text ~style:Theme.muted ~wrap:`None (clip ~max:budget l) ]
  in
  List.map line lines @ if overflow > 0 then [ more_row overflow ] else []

let diff_widget patch =
  diff ~layout:Mosaic.Diff.Unified ~theme:Mosaic.Diff.default_theme
    ~show_line_numbers:true ~wrap:`Word
    ~text_style:(Ansi.Style.make ~fg:Theme.color_muted ())
    ~size:{ width = pct 100; height = auto }
    patch

let diff_view ~width files =
  let one_file f =
    box ~flex_direction:Flex_direction.Column ~padding:diff_pad
      ~size:{ width = pct 100; height = auto }
      [ diff_widget f.patch ]
  in
  match files with
  | [] -> []
  | [ f ] -> [ one_file f ]
  | files ->
      (* Multiple files carry a title row each so the diffs stay attributable
         (02-tools.md §File edits); a long path label indents 6 and clips. *)
      let label_budget = Stdlib.max 4 (width - 6) in
      List.map
        (fun f ->
          box ~flex_direction:Flex_direction.Column
            ~size:{ width = pct 100; height = auto }
            [
              box ~flex_direction:Flex_direction.Row ~padding:preview_pad
                ~size:{ width = pct 100; height = px 1 }
                [ seg Theme.muted (clip ~max:label_budget f.label) ];
              one_file f;
            ])
        files

(* Todo glyphs (02-tools.md §Todo block). REPORTED as a theme delta: ◼/◻ (and,
   once the disclosure lens can expand the folded done rows, the struck-through
   done style) belong in theme.ml, but that module is out of this workstream's
   scope, so they live here until it lands. *)
let todo_running_glyph = "◼"
let todo_pending_glyph = "◻"

let todo_view ~width items =
  (* Done items fold to one [… N done ▸] row so the running and pending work
     stays visible (02-tools.md §Todo block); the running and pending rows keep
     their order. *)
  let done_count = List.length (List.filter (fun i -> i.status = Done) items) in
  let active = List.filter (fun i -> i.status <> Done) items in
  (* Rows indent 6 and carry a 2-column glyph, then the content, which never
     wraps — clip it so a long task line never runs off the edge. *)
  let content_budget = Stdlib.max 4 (width - 8) in
  let row glyph style content =
    box ~flex_direction:Flex_direction.Row ~padding:preview_pad
      ~size:{ width = pct 100; height = px 1 }
      [
        seg style (glyph ^ " ");
        text ~style ~wrap:`None (clip ~max:content_budget content);
      ]
  in
  let active_rows =
    List.map
      (fun i ->
        match i.status with
        | Active -> row todo_running_glyph Theme.running i.content
        | Pending -> row todo_pending_glyph Ansi.Style.default i.content
        | Done -> assert false)
      active
  in
  let done_fold =
    if done_count = 0 then []
    else
      [
        box ~flex_direction:Flex_direction.Row ~padding:preview_pad
          ~size:{ width = pct 100; height = px 1 }
          [
            seg Theme.muted
              (Printf.sprintf "%s … %d done" Theme.gutter done_count);
          ];
      ]
  in
  active_rows @ done_fold

let detail_view ~width = function
  | Summary -> []
  | Diff files -> diff_view ~width files
  | Preview { lines; overflow } -> preview_view ~width lines overflow
  | Todos items -> todo_view ~width items

let view ~width t =
  (* The todo board carries its counts in the header argument and its rows as the
     detail — it has no [⎿ summary] line (02-tools.md §Todo block); every other
     tool renders the summary line above its detail. *)
  let body =
    match t.detail with
    | Todos _ -> detail_view ~width t.detail
    | Summary | Diff _ | Preview _ ->
        result ~disclosable:t.disclosable ~summary:t.summary ~facts:t.facts ()
        :: detail_view ~width t.detail
  in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    (header t.verb
       ~argument:(header_argument ~width ~verb:t.verb t.argument)
       ~dot:t.dot
    :: body)
