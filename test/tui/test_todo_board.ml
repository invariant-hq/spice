(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The LIVE todo board — the status-strip mirror above the composer
   (doc/ui-design/02-tools.md §Todo block, strip mirror;
   doc/plans/tui-next-todo-board.md) — re-expressed as full-frame goldens. This is
   NOT the settled [⏺ Todo(…)] transcript block (that is test_tools.ml's "todo
   boards land at their call sites"): the mirror is ephemeral chrome that renders
   while a turn with a board is in flight, bounded by the [┈] strip rule, and
   persists past settle only while items are still open.

   Fixture idiom: the turn calls [todo_write] (host-handled), then a HELD
   follow-up step keeps the turn in flight with [Turn.todo_board] set, so the
   mirror is observable before settle — the tool-call wire from test_tools with a
   gated final. The board's height ladder is budget-driven
   ([max_rows = max 1 (min 8 (rows - 11))]), so the degradation cases pin the
   terminal height. Under the virtual clock the working line's elapsed is a stable
   [0s], so the whole frame goldens where the old pty suite retreated to facts. *)

(* A [todo_write] call the host runs for real, matched on the request body. *)
let todo ~expect ~id ~call_id board =
  Provider_script.tool_call ~expect ~id ~call_id ~name:"todo_write"
    ~arguments:board ()

(* The held follow-up step: matched on the tool result it now carries, held on the
   [fin] gate so the mirror is observable while the turn is in flight. *)
let final ~id answer =
  Provider_script.message ~expect:[ "function_call_output" ] ~gate:"fin" ~id
    answer

(* A seven-item board exercising the fold ladder: one running, four pending, two
   done. At the full budget the mirror shows the running and all pending rows plus
   a [… 2 done ▸] digest; as the budget tightens the pending fold to [… +4 more ▸]
   and finally the whole board to one count line. *)
let board_seven =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the mli","status":"pending","priority":"medium","position":1},{"id":"t3","content":"wire the shell","status":"pending","priority":"medium","position":2},{"id":"t4","content":"add the tests","status":"pending","priority":"medium","position":3},{"id":"t5","content":"update the plan","status":"pending","priority":"low","position":4},{"id":"t6","content":"read the spec","status":"completed","priority":"high","position":5},{"id":"t7","content":"grep the host","status":"completed","priority":"medium","position":6}]}|}

(* Two boards for the replacement test: the first has the scaffold running, the
   second promotes the tests to running with the scaffold done. *)
let board_early =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"pending","priority":"medium","position":1}]}|}

let board_late =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"completed","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"in_progress","priority":"medium","position":1}]}|}

let board_all_done =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"completed","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"completed","priority":"medium","position":1}]}|}

(* {2 The mirror renders mid-flight and persists past settle} *)

(* The mirror renders above the composer while the turn is in flight — bounded by
   the [┈] rule, running [◼] accent, pending [◻] default, done folded to the
   [… N done ▸] digest — and, because board_seven has open items, PERSISTS on
   settle (detached work stays visible), with the settled [⏺ Todo(…)] block as the
   record. *)
let%expect_test "the live board mirrors mid-flight and persists past settle" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-m1" ~call_id:"c-m1" board_seven;
      final ~id:"r-mf" "Planned the work.";
    ]
  in
  Tui.run ~name:"todo-mirror" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  (* Mid-flight: the mirror is up, the turn in flight. *)
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
13 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
14 |   ◻ 7 tasks · 2 done · 1 running
15 |   ◼ scaffold the module
16 |   ◻ write the mli
17 |   ◻ wire the shell
18 |   ◻ add the tests
19 |   ◻ update the plan
20 |   … 2 done ▸
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗       ? for shortcuts|}];
  Tui.release t "fin";
  Tui.settle t;
  (* Settled: the mirror persists (open items), the working line is gone, the
     settled block remains. *)
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
12 | ⏺ Planned the work.
13 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
14 |   ◻ 7 tasks · 2 done · 1 running
15 |   ◼ scaffold the module
16 |   ◻ write the mli
17 |   ◻ wire the shell
18 |   ◻ add the tests
19 |   ◻ update the plan
20 |   … 2 done ▸
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗       ? for shortcuts|}]

(* {2 The height ladder} *)

(* A short terminal tightens the budget so the pending rows fold: at 15 rows
   (max_rows 4) the mirror keeps the count header and the running row and folds all
   four pending into one [… +4 more ▸] row — a fold the transcript block never
   does, so it is the mirror's own signature. *)
let%expect_test "a short terminal folds the pending rows to an overflow row" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-s1" ~call_id:"c-s1" board_seven;
      final ~id:"r-sf" "Planned the work.";
    ]
  in
  Tui.run ~name:"todo-fold" ~size:(80, 15) ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |       ◻ wire the shell
02 |       ◻ add the tests
03 |       ◻ update the plan
04 |       ⎿ … 2 done ▸
05 |
06 | ⠋ Working… (0s · esc to interrupt)
07 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
08 |   ◻ 7 tasks · 2 done · 1 running
09 |   ◼ scaffold the module
10 |   … +4 more ▸
11 |   … 2 done ▸
12 | ────────────────────────────────────────────────────────────────────────────────
13 | ❯ queue a message — sends after this turn
14 | ────────────────────────────────────────────────────────────────────────────────
15 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* A very short terminal tightens the budget to one row, so the whole board
   collapses to the single [◻ N tasks · D done · R running] count line — the mark
   the transcript block never renders (its header is [⏺ Todo(…)]). *)
let%expect_test "a very short terminal collapses the board to a count line" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-d1" ~call_id:"c-d1" board_seven;
      final ~id:"r-df" "Planned the work.";
    ]
  in
  Tui.run ~name:"todo-digest" ~size:(80, 12) ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |       ◻ wire the shell
02 |       ◻ add the tests
03 |       ◻ update the plan
04 |       ⎿ … 2 done ▸
05 |
06 | ⠋ Working… (0s · esc to interrupt)
07 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
08 |   ◻ 7 tasks · 2 done · 1 running
09 | ────────────────────────────────────────────────────────────────────────────────
10 | ❯ queue a message — sends after this turn
11 | ────────────────────────────────────────────────────────────────────────────────
12 |   $PROJECT · gpt-5.5 medium · dune: ✗       ? for shortcuts|}]

(* {2 Replacement and lifecycle} *)

(* A replacement todo_write re-renders the latest board in place, never stacks:
   two consecutive writes and the mirror shows the second board's running item
   ([write the tests] promoted), the first board's scaffold folded into the done
   digest — [Turn.todo_board] returns the latest and the mirror is stateless over
   it. *)
let%expect_test "a replacement todo_write re-renders the latest board" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-r1" ~call_id:"c-r1" board_early;
      todo ~expect:[ "function_call_output" ] ~id:"r-r2" ~call_id:"c-r2"
        board_late;
      final ~id:"r-rf" "Re-planned the work.";
    ]
  in
  Tui.run ~name:"todo-replace" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ plan the work
07 |
08 | ⏺ Todo(2 tasks · 1 done · 1 running)
09 |       ◼ write the tests
10 |       ⎿ … 1 done ▸
11 |
12 | ⠋ Working… (0s · esc to interrupt)
13 |
14 |
15 |
16 |
17 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
18 |   ◻ 2 tasks · 1 done · 1 running
19 |   ◼ write the tests
20 |   … 1 done ▸
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* An interrupt mid-flight settles the turn, but the board has open items, so the
   mirror PERSISTS (stopping to see where the work stands is what the interrupt is
   for). The held final is never released, so the cooperative interrupt cannot
   self-complete — the third esc forces it. *)
let%expect_test "an interrupt keeps the board on screen while items are open" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-i1" ~call_id:"c-i1" board_seven;
      final ~id:"r-if" "This never renders.";
    ]
  in
  Tui.run ~name:"todo-interrupt" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle_turn t;
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
12 | ◌ Interrupted — tell spice what to do differently.
13 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
14 |   ◻ 7 tasks · 2 done · 1 running
15 |   ◼ scaffold the module
16 |   ◻ write the mli
17 |   ◻ wire the shell
18 |   ◻ add the tests
19 |   ◻ update the plan
20 |   … 2 done ▸
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* The board leaves the strip only when EVERY item is terminal: a first write with
   an open item shows the mirror, a second write marking all items completed clears
   it — even though the turn is still in flight (visibility tracks open items, not
   turn state). *)
let%expect_test "a board with every item terminal leaves the strip" =
  let script =
    [
      todo ~expect:[ "plan" ] ~id:"r-e1" ~call_id:"c-e1" board_early;
      todo ~expect:[ "function_call_output" ] ~id:"r-e2" ~call_id:"c-e2"
        board_all_done;
      final ~id:"r-ef" "All done.";
    ]
  in
  Tui.run ~name:"todo-terminal" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ plan the work
07 |
08 | ⏺ Todo(2 tasks · 2 done · 0 running)
09 |       ⎿ … 2 done ▸
10 |
11 | ⠋ Working… (0s · esc to interrupt)
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

[%%run_tests "spice.tui.todo-board"]
