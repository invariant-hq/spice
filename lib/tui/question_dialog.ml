(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
module Q = Spice_protocol.Question

module Inline_input = struct
  type t = { text : string; cursor : int }

  type outcome = Stay of t | Submit of string | Cancel

  let empty = { text = ""; cursor = 0 }
  let text (t : t) = t.text
  let cursor (t : t) = t.cursor

  let is_boundary text pos =
    pos = 0
    || pos = String.length text
    || Char.code (String.get text pos) land 0xC0 <> 0x80

  let previous_boundary text pos =
    let rec find pos =
      if pos = 0 || is_boundary text pos then pos else find (pos - 1)
    in
    find (max 0 (pos - 1))

  let next_boundary text pos =
    let limit = String.length text in
    let rec find pos =
      if pos = limit || is_boundary text pos then pos else find (pos + 1)
    in
    find (min limit (pos + 1))

  let insert inserted (t : t) =
    let before = String.sub t.text 0 t.cursor in
    let after =
      String.sub t.text t.cursor (String.length t.text - t.cursor)
    in
    {
      text = before ^ inserted ^ after;
      cursor = t.cursor + String.length inserted;
    }

  let backspace (t : t) =
    if t.cursor = 0 then t
    else
      let first = previous_boundary t.text t.cursor in
      let before = String.sub t.text 0 first in
      let after =
        String.sub t.text t.cursor (String.length t.text - t.cursor)
      in
      { text = before ^ after; cursor = first }

  let key ev (t : t) =
    match Panel.classify ev with
    | Panel.Printable text -> Stay (insert text t)
    | Panel.Digit digit -> Stay (insert (string_of_int digit) t)
    | Panel.Action Panel.Left ->
        Stay { t with cursor = previous_boundary t.text t.cursor }
    | Panel.Action Panel.Right ->
        Stay { t with cursor = next_boundary t.text t.cursor }
    | Panel.Action Panel.Backspace -> Stay (backspace t)
    | Panel.Action Panel.Enter -> Submit (String.trim t.text)
    | Panel.Action Panel.Escape -> Cancel
    | Panel.Action
        (Panel.Tab | Panel.Up | Panel.Down | Panel.Ctrl_d | Panel.Other) ->
        Stay t

  let paste text t = insert text t
end

type t = {
  header : string option;
  question : string;
  options : Q.Option.t list;
  multi : bool;
  checked : bool array;
  (* The cursor ranges over the options and the trailing [✎] custom row, so its
     count is [List.length options + 1]. *)
  nav : Option_list.t;
  input : Inline_input.t option;
  flash : string option;
}

let build ~header ~question ~options ~multi =
  {
    header;
    question;
    options;
    multi;
    checked = Array.make (List.length options) false;
    nav = Option_list.make ~count:(List.length options + 1);
    input = None;
    flash = None;
  }

let of_request request =
  build ~header:(Q.Request.header request)
    ~question:(Q.Request.question request)
    ~options:(Q.Request.options request)
    ~multi:(Q.Request.multi request)

let of_text text = build ~header:None ~question:text ~options:[] ~multi:false

type outcome = Stay | Answer of string | Flash of string

let option_count t = List.length t.options
let custom_index t = option_count t (* 0-based index of the ✎ row *)

let checked_labels t =
  List.filteri (fun i _ -> t.checked.(i)) t.options |> List.map Q.Option.label

(* Resolve the confirmed 0-based row index [i]. *)
let confirm t i =
  if i = custom_index t then ({ t with input = Some Inline_input.empty }, Stay)
  else if t.multi then
    (* Enter on an option in multi-select submits the checked set. *)
    match checked_labels t with
    | [] ->
        let message = "choose at least one" in
        ({ t with flash = Some message }, Flash message)
    | labels -> (t, Answer (String.concat ", " labels))
  else (t, Answer (Q.Option.label (List.nth t.options i)))

let toggle t i =
  if i < option_count t then (
    t.checked.(i) <- not t.checked.(i);
    ({ t with flash = None }, Stay))
  else ({ t with input = Some Inline_input.empty }, Stay)

let key ev t =
  let t = { t with flash = None } in
  match t.input with
  | Some input -> (
      match Inline_input.key ev input with
      | Inline_input.Stay input -> ({ t with input = Some input }, Stay)
      | Inline_input.Cancel -> ({ t with input = None }, Stay)
      | Inline_input.Submit "" ->
          let message = "type an answer" in
          ({ t with flash = Some message }, Flash message)
      | Inline_input.Submit text -> (t, Answer text))
  | None -> (
      match Panel.classify ev with
      | Panel.Digit d when d >= 1 && d <= option_count t + 1 ->
          let i = d - 1 in
          if t.multi && i < option_count t then toggle t i
          else ({ t with nav = Option_list.jump d t.nav }, Stay)
      | Panel.Digit _ -> (t, Stay)
      | Panel.Printable " " when t.multi ->
          toggle t (Option_list.selected t.nav)
      | Panel.Action Panel.Up -> ({ t with nav = Option_list.up t.nav }, Stay)
      | Panel.Action Panel.Down ->
          ({ t with nav = Option_list.down t.nav }, Stay)
      | Panel.Action Panel.Enter -> confirm t (Option_list.selected t.nav)
      | Panel.Action Panel.Escape ->
          ({ t with input = Some Inline_input.empty }, Stay)
      | Panel.Printable _ | Panel.Action _ -> (t, Stay))

let accepts_paste t = Option.is_some t.input

let paste text t =
  match t.input with
  | Some input -> { t with input = Some (Inline_input.paste text input) }
  | None -> t

let hint t =
  if Option.is_some t.input then
    [ "type answer"; "enter submit"; "esc cancel"; "paste works" ]
  else if t.multi then
    [ "space toggle"; "1-9 toggle"; "enter submit"; "esc type your own" ]
  else [ "1-9 choose"; "enter answer"; "esc type your own" ]

let indent = padding_lrtb 2 2 0 0
let blank = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let option_row t i option =
  let selected = Option_list.selected t.nav = i in
  let checkbox =
    if t.multi then
      if t.checked.(i) then Option_list.Checked else Option_list.Unchecked
    else Option_list.No_box
  in
  let label_style = if selected then Theme.accent else Theme.muted in
  let label =
    match Q.Option.description option with
    | None -> text ~style:label_style ~wrap:`None (Q.Option.label option)
    | Some description ->
        box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
          [
            text ~style:label_style ~wrap:`None (Q.Option.label option ^ "  ");
            text ~style:Theme.muted ~wrap:`None description;
          ]
  in
  Option_list.row ~selected ~checkbox ~number:(i + 1) ~label ()

let custom_row t =
  let i = custom_index t in
  let selected = Option_list.selected t.nav = i in
  let style = if selected then Theme.accent else Theme.muted in
  let cursor = if selected then Theme.cursor else "  " in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    [
      text ~style ~wrap:`None cursor;
      text ~style ~wrap:`None
        (string_of_int (i + 1)
        ^ ". " ^ Theme.own_answer ^ " type your own answer");
    ]

let input_rows input =
  let value = Inline_input.text input in
  let cursor = Inline_input.cursor input in
  let before = String.sub value 0 cursor in
  let after = String.sub value cursor (String.length value - cursor) in
  let rule =
    box ~padding:indent ~flex_shrink:0.
      [ text ~style:Theme.rule ~wrap:`None "───────────────────────────────" ]
  in
  [
    rule;
    box ~padding:indent ~flex_shrink:0.
      [
        text ~style:Theme.accent ~wrap:`None
          (Theme.cursor ^ before ^ "▌" ^ after);
      ];
    rule;
  ]

let view ~width t =
  let header =
    match t.header with
    | Some h ->
        [
          box ~padding:indent ~flex_shrink:0.
            [ text ~style:Theme.accent ~wrap:`Word h ];
        ]
    | None -> []
  in
  let question_row =
    box ~padding:indent ~flex_shrink:0.
      ~size:{ width = pct 100; height = auto }
      [ text ~wrap:`Word t.question ]
  in
  let option_rows =
    List.mapi (fun i option -> option_row t i option) t.options
  in
  let options =
    box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
      (match t.input with
      | None -> option_rows @ [ custom_row t ]
      | Some input -> option_rows @ input_rows input)
  in
  let flash =
    match t.flash with
    | None -> []
    | Some message ->
        [
          box ~padding:indent ~flex_shrink:0.
            [ text ~style:Theme.warning ~wrap:`None message ];
        ]
  in
  let content = header @ [ question_row; blank; options ] @ flash in
  (* The top rule is accent, not the plain [rule] gray: a decision dialog is
     spice asking, and the accent rule is its single piece of chrome (07-dialogs
     §Shared anatomy, §Theme usage; 00-overview §One rule idiom). *)
  Panel.view ~frame:Theme.color_accent ~name:"question" ~filter:""
    ~hint:(hint t) ~width ~content
