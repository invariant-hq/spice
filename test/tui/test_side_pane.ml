(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the wide-terminal side panel — the context & activity
   column right of a [│] rule (doc/plans/tui-next-side-panel.md;
   doc/ui-design/01-transcript.md §Wide terminals).

   The pane's presence is a pure function of width (open at ≥110 cols), never of
   turn state; its content varies with the turn — the live todo board while a
   board is in flight, the idle workspace glance otherwise. These tests drive the
   real binary at a wide (120) and a narrow (100) width and assert the
   load-bearing observables:

   - board routing: at ≥110 the board renders in the PANE, so the strip's [┈]
     rule is absent; at <110 it renders in the strip, so [┈] is present. This
     [┈]-presence is the double-render law made observable (the board renders in
     exactly one region).
   - idle glance: after the board settles, the wide pane shows the workspace
     glance — in a temp project only the [dune disconnected] fact (no worktree /
     CRs / session), which the footer's [dune: …] segment does not match.
   - presence by width: the [│] pane rule appears at 120 and not at 100.

   Facts, not screen goldens (the test_tools convention): the working line's
   elapsed clock and the banner are noisy. Fixture idiom reuses the todo-board
   held-step trick so the board is observable before settle. Enter is a separate
   pty write. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The 1-based screen row a needle first lands on, or 0 when absent. *)
let row_of needle screen =
  let rec find i = function
    | [] -> 0
    | line :: rest -> if Util.contains line needle then i else find (i + 1) rest
  in
  find 1 (String.split_on_char '\n' screen)

let run ?env ?rows ?cols ?provider project f =
  Term.run ?env ?rows ?cols ?provider project f

let json_strings texts =
  String.concat "," (List.map (Printf.sprintf "%S") texts)

(* A [function_call] the host runs for real, then requests a follow-up step. *)
let tool_call_line ~id ~call_id ~name ~arguments ~body_contains =
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-%s","call_id":%S,"name":%S,"arguments":%S}]}}|}
    (json_strings body_contains)
    id call_id call_id name arguments

(* The held follow-up step keeps the turn in flight long enough to observe the
   board before the answer settles. *)
let held_final ~id ~delay_ms ~answer =
  Provider.delayed_response_line ~delay_ms ~id
    ~body_contains:[ "function_call_output" ] ~body_not_contains:[] ~answer

let board_seven =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the mli","status":"pending","priority":"medium","position":1},{"id":"t3","content":"wire the shell","status":"pending","priority":"medium","position":2},{"id":"t4","content":"add the tests","status":"pending","priority":"medium","position":3},{"id":"t5","content":"update the plan","status":"pending","priority":"low","position":4},{"id":"t6","content":"read the spec","status":"completed","priority":"high","position":5},{"id":"t7","content":"grep the host","status":"completed","priority":"medium","position":6}]}|}

let todo_fixture ~id ~call_id =
  tool_call_line ~id ~call_id ~name:"todo_write" ~arguments:board_seven
    ~body_contains:[ "plan" ]

(* A plain assistant turn with no [todo_write], so no board ever enters play —
   the wide pane hosts the idle glance throughout. *)
let plain_final ~id ~answer ~body_contains =
  Provider.delayed_response_line ~delay_ms:0 ~id ~body_contains
    ~body_not_contains:[] ~answer

(* At ≥110 cols the pane opens and the board routes to it (no [┈] strip rule),
   the rows stacking vertically past the [│]. The pane is a stacked, named-section
   dashboard (Pane_sections): the [workspace] section is ambient — present even
   during a todo turn (the former XOR, where the board replaced the glance, is
   gone) — and the board is the [tasks] section below it, its counts carried by the
   section header (so the board drops its own [◻ N tasks] count line here,
   [~count_header:false]). Checked in flight, while the board is live —
   independent of board lifetime, since a board with open items may persist across
   settle (tui-next-todo-board.md). *)
let%expect_test "wide: the board routes to the pane" =
  Project.with_temp "next-pane-wide" @@ fun project ->
  let todo = todo_fixture ~id:"r-w1" ~call_id:"c-w1" in
  let final =
    held_final ~id:"r-wf" ~delay_ms:6000 ~answer:"Planned the work."
  in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:120 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "◼ scaffold the module" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "the pane rule is present at wide width" (Screen.has "│" s);
  print_fact "the board renders (its running row shows)"
    (Screen.has "◼ scaffold the module" s);
  print_fact "the board is in the pane, so the strip ┈ rule is absent"
    (Screen.lacks "┈" s);
  print_fact "the board rows stack vertically in the pane"
    (let a = row_of "◼ scaffold the module" s
     and b = row_of "◻ write the mli" s in
     a > 0 && b > 0 && a <> b);
  print_fact
    "the workspace section is present during the board turn (XOR fixed)"
    (Screen.has "workspace" s && Screen.has "dune disconnected" s);
  print_fact "the workspace header leads its own dune row (named section)"
    (let h = row_of "workspace" s and d = row_of "dune disconnected" s in
     h > 0 && d = h + 1);
  print_fact "the tasks section header carries the counts"
    (Screen.has "tasks · 2 done · 1 running" s);
  print_fact "the board's own ◻-count line is dropped in the pane"
    (Screen.lacks "◻ 7 tasks" s);
  [%expect
    {|
    the pane rule is present at wide width: true
    the board renders (its running row shows): true
    the board is in the pane, so the strip ┈ rule is absent: true
    the board rows stack vertically in the pane: true
    the workspace section is present during the board turn (XOR fixed): true
    the workspace header leads its own dune row (named section): true
    the tasks section header carries the counts: true
    the board's own ◻-count line is dropped in the pane: true|}]

(* With no board in play, the wide pane hosts the idle workspace glance. Presence
   is width-driven, so the pane is up during and after a plain turn; in a temp
   project the glance carries only the [dune disconnected] fact (no worktree / CRs
   / session), which the footer's [dune: …] segment does not match. *)
let%expect_test "wide: the idle pane hosts the workspace glance" =
  Project.with_temp "next-pane-glance" @@ fun project ->
  let final =
    plain_final ~id:"r-g1" ~answer:"Hello there." ~body_contains:[ "say hello" ]
  in
  Provider.with_responses project [ final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:120 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "say hello";
  Term.wait t (Screen.has "❯ say hello");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Hello there.");
  let s = Term.screen t in
  print_fact "the pane is present at wide width" (Screen.has "│" s);
  print_fact "the idle pane shows the workspace glance's dune fact"
    (Screen.has "dune disconnected" s);
  print_fact "the idle glance sits under its named workspace header"
    (let h = row_of "workspace" s and d = row_of "dune disconnected" s in
     h > 0 && d = h + 1);
  [%expect
    {|
    the pane is present at wide width: true
    the idle pane shows the workspace glance's dune fact: true
    the idle glance sits under its named workspace header: true|}]

(* Under a short pane the section budget keeps both sections: the ambient
   workspace floor survives (its dune line) while the [tasks] board folds itself to
   a digest ([… +N more ▸]) to fit its slice (Pane_sections §The height budget).
   At [rows:12] the pane's content budget is 7 rows — too few for the full board,
   so the fold is forced, proving the split rather than a mere fit. The composer
   and footer do not move (the layout-stability law). *)
let%expect_test "wide short: the budget keeps workspace and folds the board" =
  Project.with_temp "next-pane-short" @@ fun project ->
  let todo = todo_fixture ~id:"r-s1" ~call_id:"c-s1" in
  let final =
    held_final ~id:"r-sf" ~delay_ms:6000 ~answer:"Planned the work."
  in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:12 ~cols:120 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "◼ scaffold the module" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "the ambient workspace floor survives the short budget"
    (Screen.has "dune disconnected" s);
  print_fact "the tasks section still shows alongside it"
    (Screen.has "tasks · 2 done · 1 running" s);
  print_fact "the board folds its pending rows to a digest to fit its slice"
    (Screen.has "+4 more" s);
  print_fact "the composer and footer did not move (layout stability)"
    (Screen.has "? for shortcuts" s);
  [%expect
    {|
    the ambient workspace floor survives the short budget: true
    the tasks section still shows alongside it: true
    the board folds its pending rows to a digest to fit its slice: true
    the composer and footer did not move (layout stability): true|}]

(* Below the threshold the pane is absent: no [│] rule, and the board renders in
   the strip region above the composer, bounded by its [┈] rule. *)
let%expect_test "narrow: no pane, the board renders in the strip" =
  Project.with_temp "next-pane-narrow" @@ fun project ->
  let todo = todo_fixture ~id:"r-n1" ~call_id:"c-n1" in
  let final =
    held_final ~id:"r-nf" ~delay_ms:6000 ~answer:"Planned the work."
  in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:100 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "◼ scaffold the module" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "no pane rule below the threshold" (Screen.lacks "│" s);
  print_fact "the board renders in the strip, bounded by the ┈ rule"
    (Screen.has "┈" s && Screen.has "◼ scaffold the module" s);
  [%expect
    {|
    no pane rule below the threshold: true
    the board renders in the strip, bounded by the ┈ rule: true|}]
