(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the subagent-threads surface (doc/plans/
   tui-next-threads.md). Phase 1's parent-side gate: a real turn spawns a
   detached child through the fake provider, and while the child runs the footer
   carries the [* N agents] fact; when the child settles, its line lands once in
   the parent transcript. No switcher strip renders below the footer yet — the
   strip and its focus are later phases.

   The child's response is delayed so its run stays observable while the count is
   asserted; the fixture is unordered because the parent and the child race for
   the provider under detachment (subagent-tui.md M2). Auto-wake is disabled so a
   settling child does not start an extra parent turn the fixture would have to
   answer. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let run ?env ?rows ?cols ?provider project f =
  Term.run ?env ?rows ?cols ?provider project f

(* The parent's first step delegates: a [spawn_subagent] function_call the host
   runs for real, minting a detached child run. [body_not_contains] keeps this
   entry from also matching the parent's follow-up request (which carries the
   launch ack), under the unordered matcher. *)
let spawn_line =
  {|{"expect":{"body_contains":["delegate"],"body_not_contains":["launched"]},"response":{"id":"resp-spawn","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-spawn","call_id":"spawn-1","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"survey the code\"}"}]}}|}

let%expect_test
    "a spawned child shows the agents count and settles as a parent notice" =
  Project.with_temp "next-threads-spawn" @@ fun project ->
  (* Detached-child settle otherwise wakes the idle parent for another turn; the
     phase-1 gate wants just the settle notice, so disable the wake. *)
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  (* The parent's follow-up step, after the launch ack folds into its request. *)
  let parent_done =
    Provider.response_line ~id:"resp-parent-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated the exploration."
  in
  (* The child's own turn — held two seconds so its run is observable while the
     count is asserted, then it completes with a summary. *)
  let child =
    Provider.delayed_response_line ~delay_ms:2000 ~id:"resp-child"
      ~body_contains:[ "survey the code" ] ~body_not_contains:[]
      ~answer:"Found 3 call sites."
  in
  Provider.with_responses_unordered project [ spawn_line; parent_done; child ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "delegate exploration";
  Term.wait t (Screen.has "❯ delegate exploration");
  Term.send t Keys.enter;
  (* While the held child runs, the footer carries the live-agent fact and no
     switcher strip renders below the footer (phase 1). *)
  Term.wait t (Screen.has "* 1 agent");
  let running = Term.screen t in
  print_fact "footer shows one live agent" (Screen.has "* 1 agent" running);
  (* The below-footer switcher strip renders [main] plus the child row. *)
  print_fact "switcher strip shows the main row" (Screen.has "◯ main" running);
  print_fact "switcher strip shows the child role"
    (Screen.has "Explore" running);
  (* The child settles: its line lands once in the parent transcript, in the
     spec grammar (● Agent "<task>" finished · facts — 02-tools §Subagents), and
     the live count clears. *)
  Term.wait t (Screen.has {|Agent "survey the code" finished|});
  let settled = Term.screen t in
  print_fact "settled line names the task and finished"
    (Screen.has {|Agent "survey the code" finished|} settled);
  print_fact "settled line drops the bare-role wording"
    (Screen.lacks "subagent explore completed" settled);
  print_fact "live-agent fact cleared on settle"
    (Screen.lacks "* 1 agent" settled);
  [%expect
    {|
    footer shows one live agent: true
    switcher strip shows the main row: true
    switcher strip shows the child role: true
    settled line names the task and finished: true
    settled line drops the bare-role wording: true
    live-agent fact cleared on settle: true |}]

(* Multiple children in one turn (the case driven live): a single parent step
   spawns three subagents, and the footer count and the switcher strip both
   reflect all three while they run — proving the [* N agents] fact and the
   strip are not single-agent-only. *)
let spawn_three_line =
  {|{"expect":{"body_contains":["delegate"],"body_not_contains":["launched"]},"response":{"id":"resp-s3","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"i1","call_id":"c1","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"map the config loader\"}"},{"type":"function_call","id":"i2","call_id":"c2","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"scan the test callers\"}"},{"type":"function_call","id":"i3","call_id":"c3","name":"spawn_subagent","arguments":"{\"role\":\"verify\",\"task\":\"run the suite\"}"}]}}|}

let%expect_test "three children in one turn show the count and three strip rows"
    =
  Project.with_temp "next-threads-multi" @@ fun project ->
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  let parent_done =
    Provider.response_line ~id:"resp-m-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated three."
  in
  let held task id =
    Provider.delayed_response_line ~delay_ms:8000 ~id ~body_contains:[ task ]
      ~body_not_contains:[] ~answer:"done."
  in
  Provider.with_responses_unordered project
    [
      spawn_three_line;
      parent_done;
      held "map the config loader" "resp-c1";
      held "scan the test callers" "resp-c2";
      held "run the suite" "resp-c3";
    ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:100 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "delegate exploration";
  Term.wait t (Screen.has "❯ delegate exploration");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "* 3 agents");
  let s = Term.screen t in
  print_fact "footer counts all three live agents" (Screen.has "* 3 agents" s);
  print_fact "strip shows the main row" (Screen.has "◯ main" s);
  print_fact "strip shows an explore row" (Screen.has "Explore" s);
  print_fact "strip shows the verify row" (Screen.has "Verify" s);
  (* A running row carries its elapsed after the task (§2.1 row grammar): the
     [ · ] separator only appears when a fact follows, so it proves the running
     row is no longer factless. *)
  print_fact "a running row shows its elapsed" (Screen.has "run the suite ·" s);
  [%expect
    {|
    footer counts all three live agents: true
    strip shows the main row: true
    strip shows an explore row: true
    strip shows the verify row: true
    a running row shows its elapsed: true |}]

(* The 1-based screen row a needle first lands on, or 0 when absent. *)
let row_of needle screen =
  let rec find i = function
    | [] -> 0
    | line :: rest -> if Util.contains line needle then i else find (i + 1) rest
  in
  find 1 (String.split_on_char '\n' screen)

(* Fix 1 — wide terminals absorb the switcher into the side pane
   (doc/plans/tui-next-threads.md §2.9; 03-ia §Wide terminals). At >= 110 cols the
   pane opens and the threads rows render as its TOP tenant, ABOVE the footer; the
   below-footer strip does not render (the double-render law, the same
   strip-or-pane exclusivity the todo board follows). Position is the observable:
   [◯ main] sits above the footer's [dune:] segment when it lives in the pane,
   below it when it lives in the below-footer strip (the narrow case the other
   tests drive at <110 cols). *)
let%expect_test
    "a wide terminal hosts the switcher in the side pane, above the footer" =
  Project.with_temp "next-threads-pane" @@ fun project ->
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  let parent_done =
    Provider.response_line ~id:"resp-p-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated."
  in
  let child =
    Provider.delayed_response_line ~delay_ms:6000 ~id:"resp-p-child"
      ~body_contains:[ "survey the code" ] ~body_not_contains:[] ~answer:"Done."
  in
  Provider.with_responses_unordered project [ spawn_line; parent_done; child ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:120 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "delegate exploration";
  Term.wait t (Screen.has "❯ delegate exploration");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "* 1 agent");
  Term.wait t (Screen.has "◯ main");
  let s = Term.screen t in
  let main = row_of "◯ main" s and footer = row_of "dune:" s in
  print_fact "the switcher shows the main row" (main > 0);
  print_fact "the switcher sits above the footer (absorbed into the pane)"
    (main < footer);
  print_fact "the pane rule is present at a wide width" (Screen.has "│" s);
  [%expect
    {|
    the switcher shows the main row: true
    the switcher sits above the footer (absorbed into the pane): true
    the pane rule is present at a wide width: true |}]

(* Fix — the pane's [agents] section honors the row budget it is granted
   (Pane_sections; threads_strip.ml view unfocused glance). In the wide pane the
   switcher is a budgeted section stacked under the ambient [workspace] section, so
   its unfocused glance must fit its slice: without the fix it always drew up to
   four rows (three plus the [↓ to browse] hint) regardless of the grant, so on a
   short pane its overflow ate the section budget and the browse hint fell off the
   bottom, clipped by the pane's hidden overflow.

   The geometry is the sibling side-pane "wide short" test's: at [rows:12] the
   pane's content budget is 7 rows — [workspace] reserves its 2-row floor, leaving
   5 for [agents], which after its blank + header slot grants the glance 3 rows.
   Three running children make four switcher rows ([main] + three), so the glance
   must fold to two rows plus the hint to fit — the hint is the observable: with
   the budget honored it renders inside the slice; without the fix it overflows
   off the bottom and is clipped. Facts, not a golden: the elapsed clock is
   noisy. *)
let%expect_test
    "wide short: the pane agents glance folds to its budget, keeping the \
     browse hint" =
  Project.with_temp "next-threads-pane-short" @@ fun project ->
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  let parent_done =
    Provider.response_line ~id:"resp-ps-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated three."
  in
  let held task id =
    Provider.delayed_response_line ~delay_ms:8000 ~id ~body_contains:[ task ]
      ~body_not_contains:[] ~answer:"done."
  in
  Provider.with_responses_unordered project
    [
      spawn_three_line;
      parent_done;
      held "map the config loader" "resp-ps-c1";
      held "scan the test callers" "resp-ps-c2";
      held "run the suite" "resp-ps-c3";
    ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:12 ~cols:120 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "delegate exploration";
  Term.wait t (Screen.has "❯ delegate exploration");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "* 3 agents");
  (* Wait on the ambient glance — proof the pane rendered both sections — rather
     than on the browse hint, so a regression (hint clipped) prints [false] here
     instead of hanging on a wait that never lands. *)
  Term.wait t (Screen.has "dune disconnected");
  let s = Term.screen t in
  print_fact "the ambient workspace floor survives the short budget"
    (Screen.has "dune disconnected" s);
  print_fact "the agents section renders under its header"
    (Screen.has "agents" s && Screen.has "◯ main" s);
  print_fact "the agents glance keeps its browse hint inside its slice"
    (Screen.has "↓ to browse" s);
  print_fact "the composer and footer did not move (layout stability)"
    (Screen.has "? for shortcuts" s);
  [%expect
    {|
    the ambient workspace floor survives the short budget: true
    the agents section renders under its header: true
    the agents glance keeps its browse hint inside its slice: true
    the composer and footer did not move (layout stability): true |}]

(* The tool-header truncation fix (02-tools.md §Truncation; tool_block.ml
   header_argument): a long primary argument is pre-truncated in OCaml with a
   trailing [ … ] so the closing [)] always renders, rather than flex-clipping
   raw off the terminal edge. A [spawn_subagent] with a long task exercises the
   Task header, the case Thibaut hit. *)
let long_task =
  "Inspect the repository's skill-related tests under test/blackbox and report \
   every scenario they cover"

let spawn_long_line =
  Printf.sprintf
    {|{"expect":{"body_contains":["delegate"],"body_not_contains":["launched"]},"response":{"id":"resp-spawn2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-spawn2","call_id":"spawn-2","name":"spawn_subagent","arguments":"{\"role\":\"explore\",\"task\":\"%s\"}"}]}}|}
    long_task

let%expect_test
    "a long tool-header argument truncates with an ellipsis, not a raw clip" =
  Project.with_temp "next-threads-header-clip" @@ fun project ->
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  let parent_done =
    Provider.response_line ~id:"resp-h-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated."
  in
  let child =
    Provider.response_line ~id:"resp-h-child" ~body_contains:[ "Inspect" ]
      ~body_not_contains:[] ~answer:"Done."
  in
  Provider.with_responses_unordered project
    [ spawn_long_line; parent_done; child ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "delegate a long task";
  Term.wait t (Screen.has "❯ delegate a long task");
  Term.send t Keys.enter;
  (* The Task header renders when the spawn settles as the launch cell. *)
  Term.wait t (Screen.has "Task(@explore");
  let s = Term.screen t in
  print_fact "header renders the ellipsis before the closing paren"
    (Screen.has {|…)|} s);
  print_fact "header drops the untruncated tail (no raw clip)"
    (Screen.lacks "they cover" s);
  [%expect
    {|
    header renders the ellipsis before the closing paren: true
    header drops the untruncated tail (no raw clip): true |}]

(* The switcher focus (doc/plans/tui-next-threads.md §2.2): on an empty draft [↓]
   engages the strip, [↑/↓] walk it, [esc] releases. Drill-in ([↵]) is a later
   phase, so the strip is browse-only and shows no [enter to open] hint. *)
let%expect_test
    "the switcher strip engages, walks, and releases on the empty-draft arrows"
    =
  Project.with_temp "next-threads-focus" @@ fun project ->
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  let parent_done =
    Provider.response_line ~id:"resp-f-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated."
  in
  (* Held long enough to walk the strip while the child is live. *)
  let child =
    Provider.delayed_response_line ~delay_ms:6000 ~id:"resp-f-child"
      ~body_contains:[ "survey the code" ] ~body_not_contains:[] ~answer:"Done."
  in
  Provider.with_responses_unordered project [ spawn_line; parent_done; child ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "delegate exploration";
  Term.wait t (Screen.has "❯ delegate exploration");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "◯ main");
  (* [↓] engages: the main row takes the [❯] cursor; the drill-in hint is gated
     off (browse-only). *)
  Term.send t Keys.down;
  Term.wait t (Screen.has {|❯ ◯ main|});
  let engaged = Term.screen t in
  print_fact "down engages the strip (main selected)"
    (Screen.has {|❯ ◯ main|} engaged);
  print_fact "drill-in hint gated off (browse-only)"
    (Screen.lacks "enter to open" engaged);
  (* [↓] again walks onto the child row, deselecting main. *)
  Term.send t Keys.down;
  Term.wait t (Screen.lacks {|❯ ◯ main|});
  print_fact "down walks off main onto the child"
    (Screen.lacks {|❯ ◯ main|} (Term.screen t));
  (* [esc] releases; the strip stays, now unfocused. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "◯ main");
  let released = Term.screen t in
  print_fact "esc releases the focus" (Screen.lacks {|❯ ◯ main|} released);
  print_fact "strip remains after release" (Screen.has "◯ main" released);
  [%expect
    {|
    down engages the strip (main selected): true
    drill-in hint gated off (browse-only): true
    down walks off main onto the child: true
    esc releases the focus: true
    strip remains after release: true |}]

(* REPRO (the P0): a RESUMED session's subagent runs must reach the switcher. The
   whole existing suite drives a FRESH first-turn session, where the shell's
   [session_id] happens to equal the pre-minted [session_seed] the run is built
   with — so [owns_run] / the [Thread_runs_loaded] gate accept the runs by luck.
   On a resume the attached session id is the RESUMED id, but the shell's
   [session_id] is never re-attributed to it, so every thread event is dropped
   and nothing renders below the footer — exactly what Thibaut saw driving live. *)
let%expect_test
    "a resumed session's persisted running run shows in the switcher" =
  Project.with_temp "next-threads-resume" @@ fun project ->
  Seed.prompt_session_titled project "ses_res" ~title:"resume target"
    ~prompt:"hello from the past";
  (* A running child persisted under the resumed parent, in the artifact ledger
     the runtime loads at [enter_session]. *)
  Seed.subagent_run project ~parent:"ses_res" ~child:"ses_res-sub-1"
    ~role:"explore" ~task:"survey the code"
    ~status_json:{|{"type":"running","started_at":2000}|};
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "▔▔▔▔" s && Screen.lacks "loading sessions" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "hello from the past");
  let s = Term.screen t in
  print_fact "footer shows the resumed session's live agent"
    (Screen.has "* 1 agent" s);
  print_fact "switcher strip shows the main row" (Screen.has "◯ main" s);
  print_fact "switcher strip shows the resumed child role"
    (Screen.has "Explore" s);
  [%expect
    {|
    footer shows the resumed session's live agent: true
    switcher strip shows the main row: true
    switcher strip shows the resumed child role: true |}]

(* The full live lifecycle Thibaut hit: resume a session, then spawn a LIVE child
   in it. Before the fix the shell's [session_id] stayed the pre-minted seed, so
   [owns_run] dropped every [Thread_*] event whose parent was the RESUMED id —
   the count and strip never appeared and the settle notice never landed, exactly
   the reported symptom. This drives the live [owns_run] path (not the artifact
   load), so both gates are pinned against resume. *)
let%expect_test
    "a live spawn in a resumed session reaches the switcher and settles" =
  Project.with_temp "next-threads-resume-live" @@ fun project ->
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|};
  Seed.prompt_session_titled project "ses_live" ~title:"resume target"
    ~prompt:"hello from the past";
  let parent_done =
    Provider.response_line ~id:"resp-rl-done" ~body_contains:[ "launched" ]
      ~body_not_contains:[] ~answer:"Delegated."
  in
  let child =
    Provider.delayed_response_line ~delay_ms:2000 ~id:"resp-rl-child"
      ~body_contains:[ "survey the code" ] ~body_not_contains:[]
      ~answer:"Found 3 call sites."
  in
  Provider.with_responses_unordered project [ spawn_line; parent_done; child ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  (* Resume the seeded session, then drive a turn that spawns a detached child. *)
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "▔▔▔▔" s && Screen.lacks "loading sessions" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "hello from the past");
  Term.send t "delegate exploration";
  Term.wait t (Screen.has "❯ delegate exploration");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "* 1 agent");
  let running = Term.screen t in
  print_fact "footer counts the resumed session's live spawn"
    (Screen.has "* 1 agent" running);
  print_fact "switcher strip shows the child role"
    (Screen.has "Explore" running);
  Term.wait t (Screen.has {|Agent "survey the code" finished|});
  let settled = Term.screen t in
  print_fact "settled notice lands in the resumed parent transcript"
    (Screen.has {|Agent "survey the code" finished|} settled);
  print_fact "live-agent fact cleared on settle"
    (Screen.lacks "* 1 agent" settled);
  [%expect
    {|
    footer counts the resumed session's live spawn: true
    switcher strip shows the child role: true
    settled notice lands in the resumed parent transcript: true
    live-agent fact cleared on settle: true |}]
