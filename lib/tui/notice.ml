(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type fact =
  | Fact of string
  | Change of { added : int; removed : int }
  | Errors of int

type t =
  | Event of string
  | Echo of { command : string; result : string option }
  | Interrupt
  | Failure of { message : string; next_step : string; count : int }
  | Seam of string
  | Data of {
      source : string;
      facts : fact list;
      atom : string option;
      disclosable : bool;
    }

(* The [+A −D] pair is the single success/error moment in a notice, matched to
   the home brief: unbolded so it reads as a fact, not an outcome banner. *)
let add_style = Ansi.Style.make ~fg:Theme.color_success ()
let del_style = Ansi.Style.make ~fg:Theme.color_error ()

let row children =
  box ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = px 1 }
    children

(* An indent-2 muted line. Wrapped lines fall back to column 0 — notices are one
   line by design. *)
let event msg = text ~style:Theme.muted ~wrap:`Word ("  " ^ msg)

let echo ~command ~result =
  let head = text ~style:Theme.muted ~wrap:`None (Theme.cursor ^ command) in
  match result with
  | None -> head
  | Some result ->
      box ~flex_direction:Flex_direction.Column
        ~size:{ width = pct 100; height = auto }
        [ head; text ~style:Theme.muted ~wrap:`Word ("  " ^ result) ]

let interrupt =
  row
    [
      seg Theme.muted (Theme.interrupted ^ " ");
      text ~style:Theme.muted ~wrap:`Word
        "Interrupted — tell spice what to do differently.";
    ]

(* Failures are the one notice class carrying real prose, so the message hangs
   at column 2 like any other block: a fixed [✗] gutter and a wrapping body. The
   collapse count stays a muted seg beside the message — the message is error,
   the count is a fact. *)
let failure ~message ~next_step ~count =
  let head =
    box ~flex_direction:Flex_direction.Row
      ~size:{ width = pct 100; height = auto }
      [
        seg Theme.error (Theme.failed ^ " ");
        box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
          [
            box ~flex_direction:Flex_direction.Row
              ~size:{ width = pct 100; height = auto }
              (text ~style:Theme.error ~wrap:`Word ~flex_shrink:1. message
               ::
               (if count > 1 then
                  [ seg Theme.muted (Printf.sprintf " × %d" count) ]
                else []));
          ];
      ]
  in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    [ head; text ~style:Theme.muted ~wrap:`Word ("  " ^ next_step) ]

let repeat s n = String.concat "" (List.init (max 0 n) (fun _ -> s))

(* A labeled rule, 78 columns wide, centered in the transcript. The dashes are
   [rule], the label muted; both are copy-safe (no box characters). The label's
   width is its display width — labels carry multibyte marks (the [·] separator,
   em dashes in ages) that a byte count would mis-size. *)
let seam label =
  let width = 78 in
  let label = "  " ^ label ^ "  " in
  let label_width = Matrix.Text.measure ~width_method:`Unicode ~tab_width:2 label in
  let remaining = max 0 (width - label_width) in
  let left = remaining / 2 in
  let right = remaining - left in
  box ~flex_direction:Flex_direction.Row ~justify_content:Justify.Center
    ~size:{ width = pct 100; height = px 1 }
    [
      box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
        ~size:{ width = px width; height = px 1 }
        [
          seg Theme.rule (repeat "─" left);
          seg Theme.muted label;
          seg Theme.rule (repeat "─" right);
        ];
    ]

let fact_segs = function
  | Fact s -> [ seg Theme.muted s ]
  | Change { added; removed } ->
      [
        seg add_style (Printf.sprintf "+%d" added);
        seg Theme.muted " ";
        seg del_style (Printf.sprintf "−%d" removed);
      ]
  | Errors n ->
      [
        seg Theme.error (string_of_int n);
        seg Theme.muted (if n = 1 then " error" else " errors");
      ]

let data ~source ~facts ~atom ~disclosable =
  let sep = seg Theme.muted Theme.separator in
  let head = [ seg Theme.muted (Theme.watcher ^ " "); seg Theme.muted source ] in
  let facts = List.concat_map (fun f -> sep :: fact_segs f) facts in
  let atom =
    match atom with None -> [] | Some a -> [ sep; seg Theme.atom a ]
  in
  let disc =
    if disclosable then [ seg Theme.faint (" " ^ Theme.disclosure_closed) ]
    else []
  in
  row (head @ facts @ atom @ disc)

let view = function
  | Event msg -> event msg
  | Echo { command; result } -> echo ~command ~result
  | Interrupt -> interrupt
  | Failure { message; next_step; count } -> failure ~message ~next_step ~count
  | Seam label -> seam label
  | Data { source; facts; atom; disclosable } ->
      data ~source ~facts ~atom ~disclosable
