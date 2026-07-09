(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

type t = {
  proposal : Spice_protocol.Plan.Proposal.t;
  nav : Option_list.t;
  expanded : bool;
}

let option_count = 4

let make proposal =
  { proposal; nav = Option_list.make ~count:option_count; expanded = false }

type outcome =
  | Stay
  | Approve of { accept_edits : bool }
  | Adjust
  | Keep_planning

(* The option order the numbers name (03-ia §Dialogs, plan approval). *)
let resolve_index = function
  | 0 -> Approve { accept_edits = false }
  | 1 -> Approve { accept_edits = true }
  | 2 -> Adjust
  | _ -> Keep_planning

let ctrl_o (ev : Matrix.Input.Key.event) =
  ev.Matrix.Input.Key.modifier.Matrix.Input.Modifier.ctrl
  &&
  match ev.Matrix.Input.Key.key with
  | Matrix.Input.Key.Char u -> Uchar.equal u (Uchar.of_char 'o')
  | _ -> false

let key ev t =
  if ctrl_o ev then ({ t with expanded = not t.expanded }, Stay)
  else
    match Panel.classify ev with
    | Panel.Digit d when d >= 1 && d <= option_count ->
        (t, resolve_index (d - 1))
    | Panel.Digit _ -> (t, Stay)
    | Panel.Action Panel.Up -> ({ t with nav = Option_list.up t.nav }, Stay)
    | Panel.Action Panel.Down -> ({ t with nav = Option_list.down t.nav }, Stay)
    | Panel.Action Panel.Enter -> (t, resolve_index (Option_list.selected t.nav))
    | Panel.Action Panel.Escape -> (t, Keep_planning)
    | Panel.Printable _ | Panel.Action _ -> (t, Stay)

let max_body_lines = 8

let hint t =
  let expand = if t.expanded then [] else [ "ctrl+o expand" ] in
  [ "1-4 choose"; "enter confirm" ] @ expand @ [ "esc keep planning" ]

let title t =
  match Spice_protocol.Plan.Proposal.title t.proposal with
  | Some title -> title
  | None ->
      Spice_protocol.Plan.Id.to_string
        (Spice_protocol.Plan.Proposal.id t.proposal)

let indent = padding_lrtb 2 2 0 0
let blank = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let body_rows t =
  let lines =
    String.split_on_char '\n' (Spice_protocol.Plan.Proposal.body t.proposal)
  in
  let limit = if t.expanded then max_int else max_body_lines in
  let shown = List.filteri (fun i _ -> i < limit) lines in
  let hidden = List.length lines - List.length shown in
  let rows =
    List.map
      (fun line ->
        box ~padding:indent ~flex_shrink:0.
          ~size:{ width = pct 100; height = auto }
          [ text ~wrap:`Word line ])
      shown
  in
  if hidden > 0 then
    rows
    @ [
        box ~padding:indent ~flex_shrink:0.
          [
            text ~style:Theme.faint ~wrap:`None
              (Printf.sprintf "… %d more line%s (ctrl+o expands)" hidden
                 (if hidden = 1 then "" else "s"));
          ];
      ]
  else rows

let option_labels =
  [|
    "approve";
    "approve + " ^ Theme.posture ^ " accept edits";
    "adjust — tell the model what to change";
    "keep planning";
  |]

let options_view t =
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    (List.init option_count (fun i ->
         let selected = Option_list.selected t.nav = i in
         Option_list.row ~selected ~number:(i + 1)
           ~label:
             (text
                ~style:(if selected then Theme.accent else Theme.muted)
                ~wrap:`None option_labels.(i))
           ()))

let view ~width t =
  let content =
    [
      box ~padding:indent ~flex_shrink:0.
        [ text ~style:Theme.muted ~wrap:`Word (title t) ];
      blank;
    ]
    @ body_rows t
    @ [ blank; options_view t ]
  in
  Panel.view ~frame:Theme.color_mode_plan ~name:"plan" ~filter:"" ~hint:(hint t)
    ~width ~content
