(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

type t = { text : string; cursor : int }
type outcome = Stay of t | Submit of string | Cancel

let empty = { text = ""; cursor = 0 }

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
  let after = String.sub t.text t.cursor (String.length t.text - t.cursor) in
  { text = before ^ inserted ^ after; cursor = t.cursor + String.length inserted }

let backspace (t : t) =
  if t.cursor = 0 then t
  else
    let first = previous_boundary t.text t.cursor in
    let before = String.sub t.text 0 first in
    let after = String.sub t.text t.cursor (String.length t.text - t.cursor) in
    { text = before ^ after; cursor = first }

let key ev t =
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

let paste = insert

let indent = padding_lrtb 2 2 0 0

let rows (t : t) =
  let before = String.sub t.text 0 t.cursor in
  let after = String.sub t.text t.cursor (String.length t.text - t.cursor) in
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
