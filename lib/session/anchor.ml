(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type edge = Before | After
type t = { turn : Turn.Id.t; edge : edge }

let before_turn turn = { turn; edge = Before }
let after_turn turn = { turn; edge = After }
let turn t = t.turn
let edge t = t.edge
let equal a b = Turn.Id.equal a.turn b.turn && a.edge = b.edge

let pp ppf t =
  let edge = match t.edge with Before -> "before" | After -> "after" in
  Format.fprintf ppf "%s turn %a" edge Turn.Id.pp t.turn

let edge_jsont =
  Jsont.enum ~kind:"rewind edge" [ ("before", Before); ("after", After) ]

let jsont =
  Jsont.Object.map ~kind:"rewind anchor" (fun turn edge -> { turn; edge })
  |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:turn
  |> Jsont.Object.mem "edge" edge_jsont ~enc:edge
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
