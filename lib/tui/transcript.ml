(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type block =
  | Banner of Snapshot.t
  | User of string
  | Assistant of string
  | Reasoning of { duration_s : int; title : string option; body : string }
  | Tool of Tool_block.t
  | Notice of Notice.t

(* The document keeps its blocks reversed so append is O(1); [view] restores
   insertion order. *)
type t = block list

let empty = []

(* Fresh is the banner alone (or nothing): the drop's pre-turn screen. The
   banner self-margins, so the shell adds no blank before the tail while fresh. *)
let is_fresh = function [] | [ Banner _ ] -> true | _ :: _ -> false

(* Repeated failures collapse into a ` × N` count rather than stacking
   (01-transcript.md §Notices, failure class). This is a document law, not an
   emitter's job: appending a failure that matches the last block's message and
   next step bumps that block's count and drops the incoming one. *)
let append t block =
  match (block, t) with
  | ( Notice (Notice.Failure { message; next_step; count = _ }),
      Notice (Notice.Failure { message = pm; next_step = pn; count = pc })
      :: rest )
    when String.equal message pm && String.equal next_step pn ->
      Notice (Notice.Failure { message = pm; next_step = pn; count = pc + 1 })
      :: rest
  (* Data notices coalesce — re-render, never stack (01-transcript.md §Data
     notices). A same-source data notice replaces the previous one in place while
     that one is still the last block: a build going 2→3 errors overwrites its
     own row, and a heal folds into the standing broken line (the clean notice's
     outage fact carries the history the broken line held). Separated by any
     other block the previous notice is history, so the incoming one appends
     fresh. *)
  | ( Notice (Notice.Data { source; _ }),
      Notice (Notice.Data { source = prev; _ }) :: rest )
    when String.equal source prev ->
      block :: rest
  (* The todo board re-renders in place while it is the last block — two
     [todo_write]s with nothing between collapse to the newest board, the same
     last-block-only law as failure [× N] (02-tools.md §Todo block). A board
     separated from the previous one by any other block appends fresh; the
     earlier board is history at its own call site. Only [todo_write] produces a
     [Todo] verb, so the verb alone identifies the board. *)
  | ( Tool { Tool_block.verb = Tool_block.Todo; _ },
      Tool { Tool_block.verb = Tool_block.Todo; _ } :: rest ) ->
      block :: rest
  | _ -> block :: t

let blank_row = box ~size:{ width = pct 100; height = px 1 } []

(* A full-width [user]-background block: the marker flush at column 0 dimmed to
   chrome, the text default foreground, one column of interior right padding off
   the painted edge, and wrapped lines hanging under the text column at column 2
   (01-transcript.md §User message). *)
let user_marker_style =
  Ansi.Style.make ~fg:Theme.color_muted ~bg:Theme.color_user_bg ()

let user_block value =
  box ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = auto }
    ~background:Theme.color_user_bg
    ~padding:(padding_lrtb 0 1 0 0)
    [
      text ~style:user_marker_style ~wrap:`None ~flex_shrink:0. Theme.cursor;
      box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
        [ text ~style:Theme.user ~wrap:`Word value ];
    ]

(* [⏺] and prose, the dot muted because finished work goes quiet
   (01-transcript.md §Base grammar). The gutter hangs the prose column at
   column 2. *)
let assistant value =
  box ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = auto }
    [
      seg Theme.muted (Theme.tool ^ " ");
      box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
        [ Prose.view value ];
    ]

let reasoning ~expanded ~duration_s ~title ~body ~width =
  let head =
    let label = Printf.sprintf "%s Thought for %ds" Theme.thought duration_s in
    let has_hint = body <> "" in
    let title_seg =
      match title with
      | None -> []
      | Some title ->
          (* The head is one row (01-transcript.md §Reasoning): the title takes
             what is left after the label, its separator, and the [(ctrl+o)] hint,
             truncated with an ellipsis rather than overflowing off the row. *)
          let dw s = Matrix.Text.measure ~width_method:`Unicode ~tab_width:2 s in
          let budget =
            width - dw label - dw Theme.separator
            - if has_hint then dw "  (ctrl+o)" else 0
          in
          if budget <= 1 then []
          else
            [
              seg Theme.thinking
                (Theme.separator ^ Prims.truncate_tail ~width:budget title);
            ]
    in
    let hint = if has_hint then [ seg Theme.faint "  (ctrl+o)" ] else [] in
    box ~flex_direction:Flex_direction.Row
      ~size:{ width = pct 100; height = px 1 }
      ((seg Theme.thinking label :: title_seg) @ hint)
  in
  if expanded && body <> "" then
    box ~flex_direction:Flex_direction.Column
      ~size:{ width = pct 100; height = auto }
      [
        head;
        box ~flex_direction:Flex_direction.Row
          ~size:{ width = pct 100; height = auto }
          [
            box ~flex_shrink:0. ~size:{ width = px 2; height = auto } [];
            box ~flex_direction:Flex_direction.Column ~flex_grow:1.
              ~flex_shrink:1.
              [ Prose.thinking body ];
          ];
      ]
  else head

let render ~expanded ~width = function
  | Banner snapshot -> Banner.record snapshot ~width
  | User value -> user_block value
  | Assistant value -> assistant value
  | Reasoning { duration_s; title; body } ->
      reasoning ~expanded ~duration_s ~title ~body ~width
  | Tool tool -> Tool_block.view ~width tool
  | Notice notice -> Notice.view notice

(* The base grammar's one-blank separator (01-transcript.md §Base grammar) as a
   left fold over the blocks in insertion order: none before the first, one blank
   before each following block — except after a [Banner], whose own framing
   margin already is that blank (do not double it, 04-header-footer.md §Banner
   record). *)
let view ?(expanded = false) ~width t =
  let rec spaced prev = function
    | [] -> []
    | block :: rest ->
        let el = render ~expanded ~width block in
        let node =
          match prev with
          | None | Some (Banner _) -> [ el ]
          | Some _ -> [ blank_row; el ]
        in
        node @ spaced (Some block) rest
  in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    (spaced None (List.rev t))
