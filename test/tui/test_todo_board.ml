(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the LIVE todo board — the status-strip mirror above the
   composer (doc/ui-design/02-tools.md §Todo block, strip mirror;
   doc/plans/tui-next-todo-board.md). This is NOT the settled [⏺ Todo(…)]
   transcript block (that is test_tools.ml's "todo boards land at their call
   sites"): the mirror is ephemeral chrome that renders only while a turn with a
   board is in flight and leaves the strip on settle.

   Fixture idiom: the turn calls [todo_write] (host-handled, auto-answered), then
   a HELD follow-up step keeps the turn in flight with [Turn.todo_board] set, so
   the mirror is observable before settle — the same stream-hold trick the
   working-line and interrupt tests use. Enter is always a separate pty write
   (atomic-enter pitfall).

   Facts, not screen goldens (the test_tools.ml convention): the working line's
   elapsed clock and the banner are noisy, so each test asserts the load-bearing
   observables. The mirror is distinguished from the transcript block by the [┈]
   strip rule and by needles the block never renders — the pending-overflow
   [… +N more ▸] row and the [◻ N tasks · …] count line, both unique to the
   mirror's budget-driven fold. The board's height ladder is budget-driven
   ([max_rows = max 1 (min 8 (rows - 11))]), so the degradation cases pin [~rows]
   explicitly. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The 1-based screen row a needle first lands on, or 0 when absent — used to
   assert the mirror sits below the transcript and above the composer. *)
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

(* A [function_call] the host runs for real, then requests a follow-up step
   (matched by the follow-up's [function_call_output] body token). [arguments] is
   the tool input as a JSON string, [%S]-escaped into a JSON string literal. *)
let tool_call_line ~id ~call_id ~name ~arguments ~body_contains =
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-%s","call_id":%S,"name":%S,"arguments":%S}]}}|}
    (json_strings body_contains) id call_id call_id name arguments

(* The held follow-up step: the model's request now carries the tool result, so
   it matches on [function_call_output]. The delay holds the turn in flight long
   enough to observe the mirror before the answer settles. *)
let held_final ~id ~delay_ms ~answer =
  Provider.delayed_response_line ~delay_ms ~id
    ~body_contains:[ "function_call_output" ] ~body_not_contains:[] ~answer

(* A seven-item board that exercises every point on the fold ladder: one running
   item, four pending, two done. At the full budget the mirror shows the running
   and all pending rows plus a [… 2 done ▸] digest; as the budget tightens the
   pending fold to [… +4 more ▸] and finally the whole board to one count line. *)
let board_seven =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the mli","status":"pending","priority":"medium","position":1},{"id":"t3","content":"wire the shell","status":"pending","priority":"medium","position":2},{"id":"t4","content":"add the tests","status":"pending","priority":"medium","position":3},{"id":"t5","content":"update the plan","status":"pending","priority":"low","position":4},{"id":"t6","content":"read the spec","status":"completed","priority":"high","position":5},{"id":"t7","content":"grep the host","status":"completed","priority":"medium","position":6}]}|}

(* Two boards for the replacement test: the first has the scaffold running, the
   second promotes the tests to running with the scaffold done — so the mirror's
   running row moves from one item to the other. *)
let board_early =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"pending","priority":"medium","position":1}]}|}

let board_late =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"completed","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"in_progress","priority":"medium","position":1}]}|}

(* The mirror renders above the composer while the turn is in flight — bounded by
   the [┈] rule, running [◼] accent, pending [◻] default, done folded to the
   [… N done ▸] digest — and leaves the strip on settle, the settled [⏺ Todo(…)]
   block staying as the record (the mirror is chrome, the document is history). *)
let%expect_test "the live board mirrors mid-flight and persists past settle while open" =
  Project.with_temp "next-todo-mirror" @@ fun project ->
  let todo =
    tool_call_line ~id:"r-m1" ~call_id:"c-m1" ~name:"todo_write"
      ~arguments:board_seven ~body_contains:[ "plan" ]
  in
  let final = held_final ~id:"r-mf" ~delay_ms:6000 ~answer:"Planned the work." in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  (* During the held step the turn is in flight with the board set. *)
  Term.wait t (fun s -> Screen.has "┈" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "mirror bounded by the ┈ rule" (Screen.has "┈" s);
  print_fact "count header carries the counts"
    (Screen.has "◻ 7 tasks · 2 done · 1 running" s);
  print_fact "running row is accent ◼" (Screen.has "◼ scaffold the module" s);
  print_fact "pending row is ◻" (Screen.has "◻ write the mli" s);
  print_fact "done rows fold to the digest" (Screen.has "… 2 done" s);
  print_fact "mirror sits below the transcript block and above the composer"
    (let rule = row_of "┈" s in
     let block = row_of "⎿" s in
     let footer = row_of "? for shortcuts" s in
     block > 0 && rule > block && rule < footer);
  (* board_seven has open items (1 running, 4 pending), so on settle the mirror
     PERSISTS (02-tools.md §Todo block, revised 2026-07-08): detached work stays
     visible after the model stops. The ⏺ Todo block remains too. *)
  Term.wait t (fun s ->
      Screen.has "Planned the work." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "mirror persists past settle while items are open"
    (Screen.has "┈" s && Screen.has "◻ 7 tasks · 2 done · 1 running" s);
  print_fact "working line gone once settled"
    (Screen.lacks "esc to interrupt" s);
  print_fact "the settled ⏺ Todo block record remains"
    (Screen.has "scaffold the module" s);
  [%expect
    {|
    mirror bounded by the ┈ rule: true
    count header carries the counts: true
    running row is accent ◼: true
    pending row is ◻: true
    done rows fold to the digest: true
    mirror sits below the transcript block and above the composer: true
    mirror persists past settle while items are open: true
    working line gone once settled: true
    the settled ⏺ Todo block record remains: true|}]

(* A short terminal tightens the budget so the pending rows fold: at 24 rows the
   board shows every pending row, at 15 (max_rows 4 → the count header plus a
   3-row body budget) it keeps the count header and the running row and folds all
   four pending into one [… +4 more ▸] row — a fold the transcript block never
   does, so it is the mirror's own signature. *)
let%expect_test "a short terminal folds the pending rows to an overflow row" =
  Project.with_temp "next-todo-fold" @@ fun project ->
  let todo =
    tool_call_line ~id:"r-s1" ~call_id:"c-s1" ~name:"todo_write"
      ~arguments:board_seven ~body_contains:[ "plan" ]
  in
  let final = held_final ~id:"r-sf" ~delay_ms:6000 ~answer:"Planned the work." in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:15 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has "┈" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "count header still leads"
    (Screen.has "◻ 7 tasks · 2 done · 1 running" s);
  print_fact "running row stays in full" (Screen.has "◼ scaffold the module" s);
  print_fact "pending rows fold to the mirror's overflow row"
    (Screen.has "+4 more" s);
  print_fact "done rows still fold to the digest" (Screen.has "… 2 done" s);
  [%expect
    {|
    count header still leads: true
    running row stays in full: true
    pending rows fold to the mirror's overflow row: true
    done rows still fold to the digest: true|}]

(* A very short terminal tightens the budget to one row, so the whole board
   collapses to the single [◻ N tasks · D done · R running] count line — the
   block header's wording keyed by the pending mark, which the block itself never
   renders (its header is [⏺ Todo(…)]), so the needle is unique to the mirror. *)
let%expect_test "a very short terminal collapses the board to a count line" =
  Project.with_temp "next-todo-digest" @@ fun project ->
  let todo =
    tool_call_line ~id:"r-d1" ~call_id:"c-d1" ~name:"todo_write"
      ~arguments:board_seven ~body_contains:[ "plan" ]
  in
  let final = held_final ~id:"r-df" ~delay_ms:6000 ~answer:"Planned the work." in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:12 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "◻ 7 tasks");
  let s = Term.screen t in
  print_fact "the board is the single count line"
    (Screen.has "◻ 7 tasks · 2 done · 1 running" s);
  print_fact "no item rows render in the collapsed board"
    (Screen.lacks "◻ write the mli" s);
  [%expect
    {|
    the board is the single count line: true
    no item rows render in the collapsed board: true|}]

(* A replacement todo_write re-renders the latest board in place, never stacks:
   two consecutive writes and the mirror shows the second board's running item
   ([write the tests] promoted to running), the first board's scaffold folded
   into the done digest — [Turn.todo_board] returns the latest and the mirror is
   stateless over it. *)
let%expect_test "a replacement todo_write re-renders the latest board" =
  Project.with_temp "next-todo-replace" @@ fun project ->
  let todo1 =
    tool_call_line ~id:"r-r1" ~call_id:"c-r1" ~name:"todo_write"
      ~arguments:board_early ~body_contains:[ "plan" ]
  in
  let todo2 =
    tool_call_line ~id:"r-r2" ~call_id:"c-r2" ~name:"todo_write"
      ~arguments:board_late ~body_contains:[ "function_call_output" ]
  in
  let final = held_final ~id:"r-rf" ~delay_ms:6000 ~answer:"Re-planned the work." in
  Provider.with_responses project [ todo1; todo2; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  (* Wait for the SECOND board to land: [Turn.todo_board] returns the latest, so
     the mirror's running row moves to the promoted item. Waiting only on the [┈]
     rule could catch the first board's frame before the replacement. *)
  Term.wait t (fun s ->
      Screen.has "◼ write the tests" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "the mirror shows the latest board's running row"
    (Screen.has "◼ write the tests" s);
  print_fact "the replaced board's item folded into the done digest"
    (Screen.has "1 done" s);
  [%expect
    {|
    the mirror shows the latest board's running row: true
    the replaced board's item folded into the done digest: true|}]

(* An interrupt mid-flight settles the turn, but the board has open items, so the
   mirror PERSISTS (02-tools.md §Todo block, revised 2026-07-08) — stopping to see
   where the work stands is exactly what the interrupt is for. The settled
   [⏺ Todo(…)] block stays too. *)
let%expect_test "an interrupt keeps the board on screen while items are open" =
  Project.with_temp "next-todo-interrupt" @@ fun project ->
  let todo =
    tool_call_line ~id:"r-i1" ~call_id:"c-i1" ~name:"todo_write"
      ~arguments:board_seven ~body_contains:[ "plan" ]
  in
  let final =
    held_final ~id:"r-if" ~delay_ms:8000 ~answer:"This never renders."
  in
  Provider.with_responses project [ todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has "┈" s && Screen.has "esc to interrupt" s);
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Interrupted");
  let s = Term.screen t in
  print_fact "mirror persists past the interrupt settle while items are open"
    (Screen.has "┈" s && Screen.has "◻ 7 tasks · 2 done · 1 running" s);
  print_fact "the ⏺ Todo block record remains"
    (Screen.has "scaffold the module" s);
  print_fact "the held answer never rendered"
    (Screen.lacks "This never renders." s);
  [%expect
    {|
    mirror persists past the interrupt settle while items are open: true
    the ⏺ Todo block record remains: true
    the held answer never rendered: true|}]

(* The board leaves the strip only when EVERY item is terminal (02-tools.md §Todo
   block, revised 2026-07-08): a first write with an open item shows the mirror, a
   second write marking all items completed clears it — even though the turn is
   still in flight (visibility tracks open items, not turn state). *)
let%expect_test "a board with every item terminal leaves the strip" =
  Project.with_temp "next-todo-terminal" @@ fun project ->
  let all_done =
    {|{"todos":[{"id":"t1","content":"scaffold the module","status":"completed","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"completed","priority":"medium","position":1}]}|}
  in
  let todo1 =
    tool_call_line ~id:"r-e1" ~call_id:"c-e1" ~name:"todo_write"
      ~arguments:board_early ~body_contains:[ "plan" ]
  in
  let todo2 =
    tool_call_line ~id:"r-e2" ~call_id:"c-e2" ~name:"todo_write"
      ~arguments:all_done ~body_contains:[ "function_call_output" ]
  in
  let final = held_final ~id:"r-ef" ~delay_ms:6000 ~answer:"All done." in
  Provider.with_responses project [ todo1; todo2; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  (* The first board shows the mirror. *)
  Term.wait t (fun s -> Screen.has "┈" s && Screen.has "esc to interrupt" s);
  (* The second board completes everything; the mirror leaves even in flight. *)
  Term.wait t (fun s ->
      Screen.has "2 done · 0 running" s && Screen.has "esc to interrupt" s);
  let s = Term.screen t in
  print_fact "mirror gone once every item is terminal" (Screen.lacks "┈" s);
  print_fact "turn is still in flight" (Screen.has "esc to interrupt" s);
  [%expect
    {|
    mirror gone once every item is terminal: true
    turn is still in flight: true|}]
