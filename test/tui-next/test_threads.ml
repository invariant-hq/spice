(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The subagent-threads surface (doc/plans/tui-next-threads.md), re-expressed as
   full-frame goldens. A real turn delegates through the fake provider: a
   [spawn_subagent] function_call the host runs for real mints a detached child
   run, and while the child runs the footer carries [* N agents] and the switcher
   strip lists [◯ main] plus the child rows; when the child settles, its line
   lands once in the parent transcript as [● Agent "<task>" finished].

   The parent turn and the detached child race for the provider (subagent-tui.md
   M2), so the fixture is served UNORDERED ([~unordered:true]): each request
   consumes the first pending item whose expectation it satisfies, regardless of
   arrival order. The parent follow-up and the child are held on their own gates,
   so the mid-flight state (parent settled, child running) is observed
   deterministically, then a gate is released to settle. [subagent_wake] is
   disabled so a settling child does not start an extra parent turn the fixture
   would have to answer. *)

let no_wake project =
  Project.write project ".spice/config.json" {|{"run":{"subagent_wake":false}}|}

(* The parent's delegating step: a [spawn_subagent] function_call, run for real.
   Under the unordered matcher the initial request (arrival 1) consumes this — the
   follow-up carries the same "delegate" word but by then the item is claimed. *)
let spawn ?(role = "explore") ?(task = "survey the code") ~call_id () =
  Provider.tool_call ~expect:[ "delegate" ] ~id:("resp-" ^ call_id) ~call_id
    ~name:"spawn_subagent"
    ~arguments:(Printf.sprintf {|{"role":%S,"task":%S}|} role task)
    ()

(* The parent's follow-up step, after the launch ack folds into its request. Held
   so the parent working line is observable, then released to settle it. *)
let parent_done ?(id = "resp-parent-done") ~gate answer =
  Provider.message ~expect:[ "launched" ] ~gate ~id answer

(* A child subagent's own turn, matched on its task text and held on its gate so
   its run is observable while the count is asserted. *)
let child ?(id = "resp-child") ~gate ~task answer =
  Provider.message ~expect:[ task ] ~gate ~id answer

(* {2 Spawn, count, settle} *)

let%expect_test "a spawned child shows the agents count and settles as a notice"
    =
  let script =
    [
      spawn ~call_id:"spawn-1" ();
      parent_done ~gate:"parent" "Delegated the exploration.";
      child ~gate:"child" ~task:"survey the code" "Found 3 call sites.";
    ]
  in
  Tui.run ~name:"threads-spawn" ~unordered:true ~provider:script ~seed:no_wake
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "delegate exploration";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  (* The spawn runs; the parent follow-up and the child request both arrive. *)
  ignore (Tui.await_request t 3 : string);
  (* Settle the parent turn while the child is held: the footer carries the live
     count and the below-footer switcher strip shows [◯ main] plus the child. *)
  Tui.release t "parent";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ delegate exploration
07 |
08 | ⏺ Task(@explore — survey the code)
09 |   ⎿  done
10 |
11 | ⏺ Delegated the exploration.
12 |
13 |
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …-next-threads-spawn · gpt-5.5 medium · * 1 agent · dune: ✗  ? for shortcuts
22 |
23 |     ◯ main
24 |     • Explore   survey the code · 0s|}];
  (* The child settles: its line lands once in the parent transcript, and the
     live count clears. *)
  Tui.release t "child";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ delegate exploration
07 |
08 | ⏺ Task(@explore — survey the code)
09 |   ⎿  done
10 |
11 | ⏺ Delegated the exploration.
12 |
13 |   ● Agent "survey the code" finished · 0 tool uses · ↓ 0 tokens · 0s
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …/spice-tui-next-threads-spawn · gpt-5.5 medium · dune: ✗    ? for shortcuts
22 |
23 |     ◯ main
24 |     ✓ Explore   survey the code · 0s · ↓ 0 tokens|}]

(* {2 Three children in one turn} *)

(* A single parent step fanning out to three subagents (one terminal event with
   three [function_call] items), so the footer count and the switcher strip both
   reflect all three while they run — the [* N agents] fact and the strip are not
   single-agent-only. Two [explore] children and one [verify], so the strip shows
   the [Explore] and [Verify] role labels. *)
let%expect_test "three children in one turn show the count and three strip rows"
    =
  let script =
    [
      Provider.tool_calls ~expect:[ "delegate" ] ~id:"resp-m1"
        ~calls:
          [
            ( "c1",
              "spawn_subagent",
              {|{"role":"explore","task":"map the config loader"}|} );
            ( "c2",
              "spawn_subagent",
              {|{"role":"explore","task":"scan the test callers"}|} );
            ( "c3",
              "spawn_subagent",
              {|{"role":"verify","task":"run the suite"}|} );
          ]
        ();
      parent_done ~id:"resp-m-done" ~gate:"parent" "Delegated three.";
      child ~id:"resp-c1" ~gate:"c1" ~task:"map the config loader" "done.";
      child ~id:"resp-c2" ~gate:"c2" ~task:"scan the test callers" "done.";
      child ~id:"resp-c3" ~gate:"c3" ~task:"run the suite" "done.";
    ]
  in
  Tui.run ~name:"threads-multi" ~size:(100, 24) ~unordered:true ~provider:script
    ~seed:no_wake
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "delegate exploration";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  (* One follow-up plus three child requests all arrive. *)
  ignore (Tui.await_request t 5 : string);
  Tui.release t "parent";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |        sandbox: danger-full-access (config)
02 |
03 | ❯ delegate exploration
04 |
05 | ⏺ Task(@explore — map the config loader)
06 |   ⎿  done
07 |
08 | ⏺ Task(@explore — scan the test callers)
09 |   ⎿  done
10 |
11 | ⏺ Task(@verify — run the suite)
12 |   ⎿  done
13 |
14 | ⏺ Delegated three.
15 |
16 | ────────────────────────────────────────────────────────────────────────────────────────────────────
17 | ❯ message spice
18 | ────────────────────────────────────────────────────────────────────────────────────────────────────
19 |   …/tmp/spice-tui-next-threads-multi · gpt-5.5 medium · * 3 agents · dune: ✗       ? for shortcuts
20 |
21 |     ◯ main
22 |     • Explore   map the config loader · 0s
23 |     • Explore   scan the test callers · 0s
24 |   … 1 more (↓ to browse)|}]

(* {2 Wide terminals absorb the switcher into the side pane} *)

(* At >= 110 cols the pane opens and the threads rows render as a pane tenant
   ABOVE the footer; the below-footer strip does not render (the double-render
   law). The switcher's [◯ main] sits in the pane, above the footer's [dune:]
   segment. At 120 cols the brand line carries the untruncated cwd, so [$PROJECT]
   shifts the pane rule left on that one row — deterministic on this machine, like
   every wide-frame footer in the suite. *)
let%expect_test "a wide terminal hosts the switcher in the side pane" =
  let script =
    [
      spawn ~call_id:"spawn-1" ();
      parent_done ~gate:"parent" "Delegated.";
      child ~gate:"child" ~task:"survey the code" "Done.";
    ]
  in
  Tui.run ~name:"threads-pane" ~size:(120, 24) ~unordered:true ~provider:script
    ~seed:no_wake
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "delegate exploration";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.release t "parent";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |                                                                                 │ workspace
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium                           │   dune disconnected
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT              │
04 |        sandbox: danger-full-access (config)                                     │ agents · 1 running
05 |                                                                                 │       ◯ main
06 | ❯ delegate exploration                                                          │       • Explore   survey th… · 0s
07 |                                                                                 │
08 | ⏺ Task(@explore — survey the code)                                              │
09 |   ⎿  done                                                                       │
10 |                                                                                 │
11 | ⏺ Delegated.                                                                    │
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
24 |   $PROJECT · gpt-5.5 medium · * 1 agent · dune: ✗                      ? for shortcuts|}]

(* Under a short pane the agents glance folds to its budget while keeping the
   [↓ to browse] hint inside its slice (Pane_sections). At rows:12 three running
   children overflow the pane's agents slice, so the glance folds to two rows plus
   the hint — the hint surviving inside the slice is the observable. *)
let%expect_test
    "wide short: the pane agents glance folds, keeping the browse hint" =
  let script =
    [
      Provider.tool_calls ~expect:[ "delegate" ] ~id:"resp-ps1"
        ~calls:
          [
            ( "c1",
              "spawn_subagent",
              {|{"role":"explore","task":"map the config loader"}|} );
            ( "c2",
              "spawn_subagent",
              {|{"role":"explore","task":"scan the test callers"}|} );
            ( "c3",
              "spawn_subagent",
              {|{"role":"verify","task":"run the suite"}|} );
          ]
        ();
      parent_done ~id:"resp-ps-done" ~gate:"parent" "Delegated three.";
      child ~id:"resp-ps-c1" ~gate:"c1" ~task:"map the config loader" "done.";
      child ~id:"resp-ps-c2" ~gate:"c2" ~task:"scan the test callers" "done.";
      child ~id:"resp-ps-c3" ~gate:"c3" ~task:"run the suite" "done.";
    ]
  in
  Tui.run ~name:"threads-pane-short" ~size:(120, 12) ~unordered:true
    ~provider:script ~seed:no_wake
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "delegate exploration";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 5 : string);
  Tui.release t "parent";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ⏺ Task(@explore — scan the test callers)                                        │ workspace
02 |   ⎿  done                                                                       │   dune disconnected
03 |                                                                                 │
04 | ⏺ Task(@verify — run the suite)                                                 │ agents · 3 running
05 |   ⎿  done                                                                       │       ◯ main
06 |                                                                                 │       • Explore   map the c… · 0s
07 | ⏺ Delegated three.                                                              │     … 2 more (↓ to browse)
08 |
09 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
10 | ❯ message spice
11 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
12 |   $PROJECT · gpt-5.5 medium · * 3 agents · dune: ✗               ? for shortcuts|}]

(* {2 The tool-header truncation} *)

(* A long primary argument is pre-truncated in OCaml with a trailing [ … ] so the
   closing [)] always renders (02-tools.md §Truncation). A [spawn_subagent] with a
   long task exercises the [Task] header. *)
let long_task =
  "Inspect the repository's skill-related tests under test/blackbox and report \
   every scenario they cover"

let%expect_test "a long tool-header argument truncates with an ellipsis" =
  let script =
    [
      spawn ~call_id:"spawn-long" ~task:long_task ();
      parent_done ~gate:"parent" "Delegated.";
      child ~gate:"child" ~task:"Inspect" "Done.";
    ]
  in
  Tui.run ~name:"threads-header" ~unordered:true ~provider:script ~seed:no_wake
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "delegate a long task";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.release t "parent";
  Tui.release t "child";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ delegate a long task
07 |
08 | ⏺ Task(@explore — Inspect the repository's skill-related tests under test/…)
09 |   ⎿  done
10 |
11 | ⏺ Delegated.
12 |
13 |   ● Agent "Inspect the repository's skill-related tests …" finished · 0 tool
14 | uses · ↓ 0 tokens · 0s
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …/spice-tui-next-threads-header · gpt-5.5 medium · dune: ✗   ? for shortcuts
22 |
23 |     ◯ main
24 |     ✓ Explore   Inspect the repository's skill-relate… · 0s · ↓ 0 tokens|}]

(* {2 The switcher focus} *)

(* On an empty draft [↓] engages the strip, [↑/↓] walk it, [esc] releases
   (tui-next-threads.md §2.2). Drill-in is a later phase, so the strip is
   browse-only. Driven with the child held so the strip stays live throughout. *)
let%expect_test "the switcher strip engages, walks, and releases on the arrows"
    =
  let script =
    [
      spawn ~call_id:"spawn-1" ();
      parent_done ~gate:"parent" "Delegated.";
      child ~gate:"child" ~task:"survey the code" "Done.";
    ]
  in
  Tui.run ~name:"threads-focus" ~unordered:true ~provider:script ~seed:no_wake
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "delegate exploration";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.release t "parent";
  Tui.settle t;
  (* [↓] engages: the main row takes the [❯] cursor. *)
  Tui.keys t Keys.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ delegate exploration
07 |
08 | ⏺ Task(@explore — survey the code)
09 |   ⎿  done
10 |
11 | ⏺ Delegated.
12 |
13 |
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …-next-threads-focus · gpt-5.5 medium · * 1 agent · dune: ✗  ? for shortcuts
22 |
23 |   ❯ ◯ main
24 |     • Explore   survey the code · 0s|}];
  (* [↓] again walks onto the child row, deselecting main. *)
  Tui.keys t Keys.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ delegate exploration
07 |
08 | ⏺ Task(@explore — survey the code)
09 |   ⎿  done
10 |
11 | ⏺ Delegated.
12 |
13 |
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …-next-threads-focus · gpt-5.5 medium · * 1 agent · dune: ✗  ? for shortcuts
22 |
23 |     ◯ main
24 |   ❯ • Explore   survey the code · 0s|}];
  (* [esc] releases; the strip stays, now unfocused. *)
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ delegate exploration
07 |
08 | ⏺ Task(@explore — survey the code)
09 |   ⎿  done
10 |
11 | ⏺ Delegated.
12 |
13 |
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …-next-threads-focus · gpt-5.5 medium · * 1 agent · dune: ✗  ? for shortcuts
22 |
23 |     ◯ main
24 |     • Explore   survey the code · 0s|}]

(* {2 Resume} *)

(* A RESUMED session's subagent runs must reach the switcher: on a resume the
   attached session id is the resumed id, and the persisted running run under it
   must render below the footer (the P0 Thibaut hit driving live). This drives the
   ARTIFACT-load path — a running run persisted under the resumed parent. *)
let%expect_test
    "a resumed session's persisted running run shows in the switcher" =
  Tui.run ~name:"threads-resume" ~seed:(fun project ->
      Seed.prompt_session_titled project "ses_res" ~title:"resume target"
        ~prompt:"hello from the past";
      Seed.subagent_run project ~parent:"ses_res" ~child:"ses_res-sub-1"
        ~role:"explore" ~task:"survey the code"
        ~status_json:{|{"type":"running","started_at":2000}|})
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hello from the past
07 |
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ message spice
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …next-threads-resume · gpt-5.5 medium · * 1 agent · dune: ✗  ? for shortcuts
22 |
23 |     ◯ main
24 |     • Explore   survey the code · 16m 38s|}]

(* The full live lifecycle: resume a session, then spawn a LIVE child in it. This
   drives the live [owns_run] path (not the artifact load), so the resume
   attribution is pinned against a live spawn too. *)
let%expect_test
    "a live spawn in a resumed session reaches the switcher and settles" =
  let script =
    [
      spawn ~call_id:"spawn-1" ();
      parent_done ~gate:"parent" "Delegated.";
      child ~gate:"child" ~task:"survey the code" "Found 3 call sites.";
    ]
  in
  Tui.run ~name:"threads-resume-live" ~unordered:true ~provider:script
    ~seed:(fun project ->
      no_wake project;
      Seed.prompt_session_titled project "ses_live" ~title:"resume target"
        ~prompt:"hello from the past")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "delegate exploration";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.release t "parent";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hello from the past
07 |
08 | ❯ delegate exploration
09 |
10 | ⏺ Task(@explore — survey the code)
11 |   ⎿  done
12 |
13 | ⏺ Delegated.
14 |
15 |
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ delegate exploration
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …threads-resume-live · gpt-5.5 medium · * 1 agent · dune: ✗  ? for shortcuts
22 |
23 |     ◯ main
24 |     • Explore   survey the code · 0s|}];
  Tui.release t "child";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hello from the past
07 |
08 | ❯ delegate exploration
09 |
10 | ⏺ Task(@explore — survey the code)
11 |   ⎿  done
12 |
13 | ⏺ Delegated.
14 |
15 |   ● Agent "survey the code" finished · 0 tool uses · ↓ 0 tokens · 0s
16 |
17 |
18 | ────────────────────────────────────────────────────────────────────────────────
19 | ❯ delegate exploration
20 | ────────────────────────────────────────────────────────────────────────────────
21 |   …ce-tui-next-threads-resume-live · gpt-5.5 medium · dune: ✗  ? for shortcuts
22 |
23 |     ◯ main
24 |     ✓ Explore   survey the code · 0s · ↓ 0 tokens|}]

[%%run_tests "spice.tui-next.threads"]
