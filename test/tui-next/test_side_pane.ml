(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The wide-terminal side panel — the context & activity column right of a [│]
   rule (doc/plans/tui-next-side-panel.md; doc/ui-design/01-transcript.md §Wide
   terminals) — re-expressed as full-frame goldens. The pane's PRESENCE by width
   is pinned in test_geometry; this file pins its CONTENT and the board's routing:

   - board routing: at >= 110 the board renders in the PANE (no [┈] strip rule);
     below, in the strip. The double-render law made observable — the board
     renders in exactly one region.
   - idle glance: with no board, the wide pane hosts the workspace glance (in a
     temp project only the [dune disconnected] fact).
   - short budget: a stacked, budgeted section dashboard — the ambient [workspace]
     floor survives while the [tasks] board folds to fit its slice.

   Wide (120-col) frames embed the untruncated cwd, so [$PROJECT] shifts the pane
   rule left on the brand row — deterministic on this machine, like every
   wide-frame golden in the suite. The tool-call wire with a gated final holds the
   board in flight (the test_tools/test_todo_board idiom). *)

let todo ~expect ~id ~call_id board =
  Provider.tool_call ~expect ~id ~call_id ~name:"todo_write" ~arguments:board ()

let final ~id answer =
  Provider.message ~expect:[ "function_call_output" ] ~gate:"fin" ~id answer

let board_seven =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the mli","status":"pending","priority":"medium","position":1},{"id":"t3","content":"wire the shell","status":"pending","priority":"medium","position":2},{"id":"t4","content":"add the tests","status":"pending","priority":"medium","position":3},{"id":"t5","content":"update the plan","status":"pending","priority":"low","position":4},{"id":"t6","content":"read the spec","status":"completed","priority":"high","position":5},{"id":"t7","content":"grep the host","status":"completed","priority":"medium","position":6}]}|}

(* Drive a held todo turn to its mid-flight frame, board set. *)
let plan_and_hold t =
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  Tui.settle t

(* {2 Board routing by width} *)

(* At >= 110 cols the pane opens and the board routes to it: no [┈] strip rule, the
   rows stacking under a [tasks] section header, the ambient [workspace] section
   above it — the two-section stacked dashboard. Checked in flight, while the board
   is live. *)
let%expect_test "wide: the board routes to the pane, not the strip" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-w1" ~call_id:"c-w1" board_seven;
      final ~id:"r-wf" "Planned the work.";
    ]
  in
  Tui.run ~name:"pane-wide" ~size:(120, 24) ~provider:script @@ fun t ->
  plan_and_hold t;
  Tui.print t;
  [%expect
    {|01 |                                                                                 │ workspace
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium                           │   dune disconnected
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT                 │
04 |        sandbox: danger-full-access (config)                                     │ tasks · 2 done · 1 running
05 |                                                                                 │   ◼ scaffold the module
06 | ❯ plan the work                                                                 │   ◻ write the mli
07 |                                                                                 │   ◻ wire the shell
08 | ⏺ Todo(7 tasks · 2 done · 1 running)                                            │   ◻ add the tests
09 |       ◼ scaffold the module                                                     │   ◻ update the plan
10 |       ◻ write the mli                                                           │   … 2 done ▸
11 |       ◻ wire the shell                                                          │
12 |       ◻ add the tests                                                           │
13 |       ◻ update the plan                                                         │
14 |       ⎿ … 2 done ▸                                                              │
15 |                                                                                 │
16 | ⠋ Working… (0s · esc to interrupt)                                              │
17 |                                                                                 │
18 |                                                                                 │
19 |                                                                                 │
20 |
21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗                                     ? for shortcuts|}]

(* With no board in play, the wide pane hosts the idle workspace glance under its
   [workspace] header (in a temp project only the [dune disconnected] fact). The
   pane is width-driven, so it is up once the plain turn settles. *)
let%expect_test "wide: the idle pane hosts the workspace glance" =
  let script =
    [
      Provider.message ~expect:[ "say hello" ] ~gate:"fin" ~id:"r-g1"
        "Hello there.";
    ]
  in
  Tui.run ~name:"pane-glance" ~size:(120, 24) ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |                                                                                 │ workspace
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium                           │   dune disconnected
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT               │
04 |        sandbox: danger-full-access (config)                                     │
05 |                                                                                 │
06 | ❯ say hello                                                                     │
07 |                                                                                 │
08 | ⏺ Hello there.                                                                  │
09 |                                                                                 │
10 |                                                                                 │
11 |                                                                                 │
12 |                                                                                 │
13 |                                                                                 │
14 |                                                                                 │
15 |                                                                                 │
16 |                                                                                 │
17 |                                                                                 │
18 |                                                                                 │
19 |                                                                                 │
20 |
21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗                                   ? for shortcuts|}]

(* Under a short pane the section budget keeps both sections: the ambient
   workspace floor survives (its [dune] line) while the [tasks] board folds itself
   to a digest ([… +N more ▸]) to fit its slice (Pane_sections §The height budget).
   At rows:12 the pane's content budget is too small for the full board, so the
   fold is forced. The composer and footer do not move. *)
let%expect_test "wide short: the budget keeps workspace and folds the board" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-s1" ~call_id:"c-s1" board_seven;
      final ~id:"r-sf" "Planned the work.";
    ]
  in
  Tui.run ~name:"pane-short" ~size:(120, 12) ~provider:script @@ fun t ->
  plan_and_hold t;
  Tui.print t;
  [%expect
    {|01 |       ◻ write the mli                                                           │ workspace
02 |       ◻ wire the shell                                                          │   dune disconnected
03 |       ◻ add the tests                                                           │
04 |       ◻ update the plan                                                         │ tasks · 2 done · 1 running
05 |       ⎿ … 2 done ▸                                                              │   ◼ scaffold the module
06 |                                                                                 │   … +4 more ▸
07 | ⠋ Working… (0s · esc to interrupt)                                              │   … 2 done ▸
08 |
09 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
10 | ❯ queue a message — sends after this turn
11 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
12 |   $PROJECT · gpt-5.5 medium · dune: ✗                                    ? for shortcuts|}]

(* Below the threshold the pane is absent and the board routes to the STRIP region
   above the composer, bounded by its [┈] rule — the same board, the other region
   (the double-render law). *)
let%expect_test "narrow: no pane, the board renders in the strip" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-n1" ~call_id:"c-n1" board_seven;
      final ~id:"r-nf" "Planned the work.";
    ]
  in
  Tui.run ~name:"pane-narrow" ~size:(100, 24) ~provider:script @@ fun t ->
  plan_and_hold t;
  Tui.print t;
  [%expect
    {|01 |
02 | ❯ plan the work
03 |
04 | ⏺ Todo(7 tasks · 2 done · 1 running)
05 |       ◼ scaffold the module
06 |       ◻ write the mli
07 |       ◻ wire the shell
08 |       ◻ add the tests
09 |       ◻ update the plan
10 |       ⎿ … 2 done ▸
11 |
12 | ⠋ Working… (0s · esc to interrupt)
13 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
14 |   ◻ 7 tasks · 2 done · 1 running
15 |   ◼ scaffold the module
16 |   ◻ write the mli
17 |   ◻ wire the shell
18 |   ◻ add the tests
19 |   ◻ update the plan
20 |   … 2 done ▸
21 | ────────────────────────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗               ? for shortcuts|}]

[%%run_tests "spice.tui-next.side-pane"]
