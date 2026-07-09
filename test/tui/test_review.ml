(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* STAGED for phase 4 (doc/plans/tui-next-review.md Appendix B). Do NOT drop
   into test/tui-next/ until the review screen is wired (phase 3) AND its dune
   stanza is added in the same change — an orphan .ml in that directory is a hard
   dune error that breaks the whole test/tui-next build. Full-screen goldens are
   left empty ([%expect {||}]) for phase-4 promotion against the real binary
   (tui-next chrome differs from lib/tui: the footer is suppressed and the header
   layout may shift); print_fact expects are pre-filled with the intended
   behaviour, since those facts are the parity contract regardless of chrome.

   Blackbox coverage for the ported review screen (doc/ui-design/11-review.md):
   /review opens the two-pane screen over the worktree diff; marks and the
   verdict persist under global workspace state across processes; CR add/resolve write
   the source comment in the CR/XCR grammar; the live watcher refreshes the
   queue; a missing repository shows the problem line. The `spice review` startup
   subcommand is deferred (plan §divergence 6), so every case opens via the
   /review command. *)

open Tui_harness

let print_fact = Util.print_fact
let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]

(* The review screen opens via /review from the home stage. The stage boots with
   the default footer marker, so [Term.run]'s default ready applies; the screen
   header is the post-submit signal. Enter is a separate write (the atomic-enter
   pty artifact). *)
let run ?provider ?(cols = 80) project f =
  Term.run ?provider ~rows:24 ~cols ~env:reduced_motion project f

(* [/review] is an implemented, argument-taking command ([target]), so the slash
   palette intercepts Enter and SEEDS the draft "/review " (Palette.activate
   returns [Insert] for any command with an argument hint) rather than
   dispatching. Seeding sets the completion to closed, so a second Enter submits
   the seeded draft, which dispatches [Open_review]. (Contrast [/login], which is
   not yet [implemented], so its palette never intercepts and one Enter submits.)
   Each Enter is a separate write (the atomic-enter pty artifact). *)
let open_review t =
  Term.send t "/review";
  Term.wait t (Screen.has "/review");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "target");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Review")

let sample_code = "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 4\n"

let%expect_test "review screen marks, approves, and persists" =
  Project.with_git_fixture "review-screen" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
    Term.send t " ";
    Term.wait t (Screen.has "1/1 reviewed");
    Term.send t "a";
    Term.wait t (Screen.has "approved");
    Screen.print ~project (Term.screen t) );
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                   1/1 reviewed · approved
03 |  ▾ lib                          │lib/code.ml · reviewed · +1 −1
04 |  ❯ [✓] code.ml                M │  1   let alpha = 1
05 |                                 │  2   let beta = 2
06 |                                 │❯ 3 - let gamma = 3
07 |                                 │  3 + let gamma = 33
08 |                                 │  4   let delta = 4
09 |                                 │
10 |                                 │
11 |                                 │
12 |                                 │
13 |                                 │
14 |                                 │
15 |                                 │
16 |                                 │
17 |                                 │
18 |                                 │
19 |                                 │
20 |                                 │
21 |                                 │
22 |                                 │
23 |
24 | tab focus diff · space mark · enter open · c comment · a approve · t task spice|}];
  (* Reopen: marks, verdict, and orientation come back from workspace state. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (Screen.has "approved");
    print_fact "file row restored reviewed"
      (Screen.has "[✓] code.ml" (Term.screen t));
    print_fact "verdict restored approved"
      (Screen.has "1/1 reviewed · approved" (Term.screen t)) );
  [%expect {|file row restored reviewed: true
verdict restored approved: true|}]

let%expect_test "review screen reports a missing repository" =
  Project.with_temp "review-no-repo" @@ fun project ->
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "not inside a git");
  print_fact "error line shown"
    (Screen.has "not inside a git worktree" (Term.screen t));
  print_fact "esc affordance shown" (Screen.has "esc close" (Term.screen t));
  [%expect {|error line shown: true
esc affordance shown: true|}]

let%expect_test "review screen refreshes when the worktree changes" =
  Project.with_git_fixture "review-live-refresh" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "0/1 reviewed");
  Project.write project "notes.txt" "baseline\nreviewed live\n";
  Term.wait t ~deadline:15.0 (Screen.has "0/2 reviewed");
  let screen = Term.screen t in
  print_fact "second file appears" (Screen.has "notes.txt" screen);
  print_fact "progress reflects both units" (Screen.has "0/2 reviewed" screen);
  print_fact "refresh notice shown" (Screen.has "refreshed" screen);
  [%expect
    {|second file appears: true
progress reflects both units: true
refresh notice shown: true|}]

let%expect_test "review CR compose accepts bare bodies with CR prefixes" =
  Project.with_git_fixture "review-cr-prefix-body" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run project @@ fun t ->
  open_review t;
  Term.wait t (fun screen ->
      Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
  Term.send t "c";
  Term.wait t (Screen.has "handle: comment");
  Term.send t "CRDT state needs a note";
  Term.send t Keys.enter;
  Term.wait t (Screen.has "CR added");
  print_fact "bare CR-prefixed body written"
    (Util.contains
       (Project.read project "lib/code.ml")
       "(* CR: CRDT state needs a note *)");
  [%expect {|bare CR-prefixed body written: true|}]

let%expect_test "review screen adds and resolves CRs in source" =
  Project.with_git_fixture "review-cr-actions" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  (* [c] composes on the selected file; a bare "handle: body" draft addresses a
     recipient; enter writes the comment into the worktree. The compose input is
     app-owned and painted (plan §divergence 3): keys fold into the draft, so the
     typed text appears in the dialog exactly as here. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
    Term.send t "c";
    Term.wait t (Screen.has "handle: comment");
    Term.send t "alice: rename gamma";
    Term.wait t (Screen.has "alice: rename gamma");
    Term.send t Keys.enter;
    Term.wait t (Screen.has "CR added");
    print_fact "settle notice shown" (Screen.has "CR added" (Term.screen t)) );
  print_fact "comment written to source"
    (Util.contains
       (Project.read project "lib/code.ml")
       "(* CR alice: rename gamma *)");
  [%expect {|settle notice shown: true
comment written to source: true|}];
  (* Reopen, jump to the CR, and resolve it: the source comment converts to XCR
     with the resolver handle, keeping the recipient. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (Screen.has "CR alice: rename gamma");
    Term.send t "n";
    Term.wait t (Screen.has "❯ CR alice: rename gamma");
    Term.send t "x";
    Term.wait t (Screen.has "resolve CR on");
    Term.send t Keys.enter;
    Term.wait t (Screen.has "CR resolved");
    print_fact "resolve notice shown" (Screen.has "CR resolved" (Term.screen t))
  );
  print_fact "XCR written to source"
    (Util.contains
       (Project.read project "lib/code.ml")
       "(* XCR user for alice: rename gamma *)");
  [%expect {|resolve notice shown: true
XCR written to source: true|}]

let%expect_test "review screen edits and removes a CR" =
  Project.with_git_fixture "review-cr-edit-remove" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  (* Add a CR, then reopen and edit it (e prefilled with the canonical text,
     backspace + retype), then remove it (d, unconfirmed). The old suite pinned
     only add/resolve; edit/remove are the port's added coverage. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
    Term.send t "c";
    Term.wait t (Screen.has "handle: comment");
    Term.send t "rename gamma";
    Term.send t Keys.enter;
    Term.wait t (Screen.has "CR added") );
  print_fact "CR present after add"
    (Util.contains
       (Project.read project "lib/code.ml")
       "(* CR: rename gamma *)");
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (Screen.has "CR: rename gamma");
    Term.send t "n";
    Term.wait t (Screen.has "❯ CR");
    Term.send t "d";
    Term.wait t (Screen.has "CR removed");
    print_fact "remove notice shown" (Screen.has "CR removed" (Term.screen t))
  );
  print_fact "CR gone after remove"
    (not
       (Util.contains
          (Project.read project "lib/code.ml")
          "(* CR: rename gamma *)"));
  [%expect
    {|CR present after add: true
remove notice shown: true
CR gone after remove: true|}]

let%expect_test "line cursor steps and the compose dialog floats" =
  Project.with_git_fixture "review-line-cursor" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  (* Tab focuses the diff and seeds the line cursor at the first changed line;
     down steps one line; c opens the compose dialog anchored there. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
    Term.send t Keys.tab;
    Term.wait t (Screen.has "❯ 3 -");
    Term.send t Keys.down;
    Term.wait t (Screen.has "❯ 3 +");
    Term.send t "c";
    Term.wait t (Screen.has "CR on lib/code.ml:");
    Screen.print ~project (Term.screen t) );
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · unreviewed · +1 −1
04 |  ❯ [ ] code.ml                M │ 1   let alpha = 1
05 |                                 │ 2   let beta = 2
06 |                                 │ 3 - let gamma = 3
07 |                                 │ 3 + let gamma = 33
08 |                                 │ 4   let delta = 4
09 |                                 │
10 |                                 │
11 |
12 |             CR on lib/code.ml:3
13 |             ▏handle: comment
14 |
15 |                                 │
16 |                                 │
17 |                                 │
18 |                                 │
19 |                                 │
20 |                                 │
21 |                                 │
22 |                                 │
23 |
24 | enter add CR · esc cancel|}]

let%expect_test "commenting a removed line lands indented in the worktree" =
  Project.with_temp "review-cr-indent" @@ fun project ->
  Project.git project [ "init"; "-q" ];
  Project.write project "lib/block.ml"
    "let f () =\n  let kept = 1 in\n  let removed = 2 in\n  kept\n";
  Project.git project [ "add"; "-A" ];
  Project.git project [ "commit"; "-q"; "-m"; "baseline" ];
  Project.write project "lib/block.ml" "let f () =\n  let kept = 1 in\n  kept\n";
  (* Tab seeds the line cursor on the removed (old-side) line; the CR must anchor
     on the surviving line beneath it and take the block's indentation. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let kept" screen);
    Term.send t Keys.tab;
    Term.send t "c";
    Term.wait t (Screen.has "CR on lib/block.ml:");
    Term.send t "fix: keep this";
    Term.wait t (Screen.has "fix: keep this");
    Term.send t Keys.enter;
    Term.wait t (Screen.has "CR added");
    print_fact "settle notice shown" (Screen.has "CR added" (Term.screen t)) );
  print_fact "comment indented like the block"
    (Util.contains
       (Project.read project "lib/block.ml")
       "\n  (* CR fix: keep this *)\n");
  [%expect {|settle notice shown: true
comment indented like the block: true|}]

let%expect_test "commenting a deletion hunk lands at the deletion site" =
  Project.with_temp "review-cr-hunk-indent" @@ fun project ->
  Project.git project [ "init"; "-q" ];
  Project.write project "lib/block.ml"
    "let f () =\n  let kept = 1 in\n  let removed = 2 in\n  kept\n";
  Project.git project [ "add"; "-A" ];
  Project.git project [ "commit"; "-q"; "-m"; "baseline" ];
  Project.write project "lib/block.ml" "let f () =\n  let kept = 1 in\n  kept\n";
  (* Down selects the hunk scope from the nav pane. Pure deletion hunks still
     anchor where the deleted line lived, not at the top of the file. *)
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let kept" screen);
    Term.send t Keys.down;
    Term.wait t (Screen.has "hunk 1/1");
    Term.send t "c";
    Term.wait t (Screen.has "CR on lib/block.ml:");
    Term.send t "fix: keep this";
    Term.send t Keys.enter;
    Term.wait t (Screen.has "CR added");
    print_fact "settle notice shown" (Screen.has "CR added" (Term.screen t)) );
  let source = Project.read project "lib/block.ml" in
  print_fact "hunk comment indented like the block"
    (Util.contains source "\n  (* CR fix: keep this *)\n  kept\n");
  print_fact "hunk comment not inserted at top"
    (not (String.starts_with ~prefix:"(* CR fix: keep this *)" source));
  [%expect
    {|settle notice shown: true
hunk comment indented like the block: true
hunk comment not inserted at top: true|}]

let%expect_test "esc leaves the review and returns to the stage" =
  Project.with_git_fixture "review-esc" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "0/1 reviewed");
  (* esc ladder: the cursor lands on the first file (nav focus), so one esc
     closes the screen and returns to the home stage (11-review §Keybindings).
     The home stage is proven by its inset composer placeholder, which the review
     screen never shows — a stable marker unlike the footer's [? for shortcuts]
     hint, which the logged-out [/login] nudge crowds out at this width. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "message spice");
  print_fact "review closed" (Screen.lacks "reviewed · pending" (Term.screen t));
  print_fact "back on the home stage"
    (Screen.has "message spice" (Term.screen t));
  [%expect {|review closed: true
back on the home stage: true|}]

(* [spice review] launches the process straight onto the review screen
   (Startup [Launch_review], bin/cli_tui.ml review_command) — the home stage
   never shows — and closing the screen quits: unlike the in-app [/review]
   above, there is no stage behind it to return to. *)
let%expect_test "spice review launches onto the screen and its close quits" =
  Project.with_git_fixture "review-launch" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  Term.run project ~rows:24 ~cols:80 ~env:reduced_motion ~command:[ "review" ]
    ~ready:(Screen.has "0/1 reviewed")
  @@ fun t ->
  print_fact "review screen at launch"
    (Screen.has "0/1 reviewed" (Term.screen t));
  print_fact "home stage never shown"
    (Screen.lacks "message spice" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait_exit t;
  print_fact "process exited on close" (Term.exited t);
  [%expect
    {|
    review screen at launch: true
    home stage never shown: true
    process exited on close: true |}]

let%expect_test "space on a reviewed unit unmarks it" =
  Project.with_git_fixture "review-unmark" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run project @@ fun t ->
  open_review t;
  Term.wait t (fun screen ->
      Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
  Term.send t " ";
  Term.wait t (Screen.has "1/1 reviewed");
  (* The single unit is complete, so the cursor stays on it; a second space
     unmarks and stays (never a hidden third state — 11-review §Nav pane). *)
  Term.send t " ";
  Term.wait t (Screen.has "0/1 reviewed");
  print_fact "unmark returns to unreviewed"
    (Screen.has "0/1 reviewed" (Term.screen t));
  print_fact "mark box cleared" (Screen.has "[ ] code.ml" (Term.screen t));
  [%expect {|unmark returns to unreviewed: true
mark box cleared: true|}]

let%expect_test "approving then editing stales the verdict" =
  Project.with_git_fixture "review-stale" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (fun screen ->
        Screen.has "0/1 reviewed" screen && Screen.has "let alpha" screen);
    Term.send t " ";
    Term.wait t (Screen.has "1/1 reviewed");
    Term.send t "a";
    Term.wait t (Screen.has "approved");
    print_fact "fresh approval is not stale"
      (Screen.lacks "stale" (Term.screen t));
    (* Change the approved content behind the screen; the watcher refreshes and
       the verdict — bound to the old feature content — goes visibly stale,
       never silently fresh (11-review §Verdict and staleness). *)
    Project.write project "lib/code.ml"
      "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 44\n";
    Term.wait t ~deadline:15.0 (Screen.has "stale");
    print_fact "verdict staled after edit"
      (Screen.has "approved · stale" (Term.screen t));
    Term.send t "a";
    Term.wait t (Screen.has "0/1 reviewed · approved");
    print_fact "stale approval toggles to fresh approval"
      (Screen.has "0/1 reviewed · approved" (Term.screen t)) );
  ( run project @@ fun t ->
    open_review t;
    Term.wait t (Screen.has "0/1 reviewed · approved");
    print_fact "fresh reapproval persisted"
      (Screen.has "0/1 reviewed · approved" (Term.screen t)) );
  [%expect
    {|fresh approval is not stale: true
verdict staled after edit: true
stale approval toggles to fresh approval: true
fresh reapproval persisted: true|}]

let%expect_test "the key table toggles with ?" =
  Project.with_git_fixture "review-help" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "0/1 reviewed");
  Term.send t "?";
  Term.wait t (Screen.has "mark reviewed and advance");
  print_fact "key table shows the space binding"
    (Screen.has "mark reviewed and advance" (Term.screen t));
  print_fact "key table shows focus switch"
    (Screen.has "switch focus" (Term.screen t));
  (* ? again closes the table and restores the body. *)
  Term.send t "?";
  Term.wait t (Screen.lacks "mark reviewed and advance");
  print_fact "key table toggled off"
    (Screen.lacks "mark reviewed and advance" (Term.screen t));
  [%expect
    {|key table shows the space binding: true
key table shows focus switch: true
key table toggled off: true|}]

let%expect_test "below 80 columns the split collapses to one focused pane" =
  Project.with_git_fixture "review-narrow" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run ~cols:70 project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "0/1 reviewed");
  (* Narrow shows a single full-width pane, the focused one (nav on open); the
     diff body is not on screen beside it. *)
  print_fact "nav pane shown" (Screen.has "code.ml" (Term.screen t));
  print_fact "diff not shown beside nav"
    (Screen.lacks "let alpha" (Term.screen t));
  (* tab swaps which pane is shown (the old drill-in as a width degradation). *)
  Term.send t Keys.tab;
  Term.wait t (Screen.has "let alpha");
  print_fact "tab swaps to the diff pane"
    (Screen.has "let alpha" (Term.screen t));
  [%expect
    {|nav pane shown: true
diff not shown beside nav: true
tab swaps to the diff pane: true|}]

let%expect_test "a clean worktree shows the empty state" =
  Project.with_git_fixture "review-empty" @@ fun project ->
  (* with_git_fixture commits its files, so with no further writes the worktree
     matches HEAD and there is nothing to review (11-review §States). *)
  run project @@ fun t ->
  Term.send t "/review";
  Term.wait t (Screen.has "/review");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "target");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "no changes to review");
  print_fact "empty state shown"
    (Screen.has "no changes to review — the worktree matches" (Term.screen t));
  print_fact "esc affordance shown" (Screen.has "esc close" (Term.screen t));
  [%expect {|empty state shown: true
esc affordance shown: true|}]

(* A 30-line file whose second and twenty-ninth lines change: at 12 context lines
   the two edits fall in separate hunks. *)
let two_hunk_base =
  String.concat ""
    (List.init 30 (fun i -> Printf.sprintf "let v%d = %d\n" (i + 1) (i + 1)))

let two_hunk_tip =
  String.concat ""
    (List.init 30 (fun i ->
         let n = i + 1 in
         if n = 2 || n = 29 then Printf.sprintf "let v%d = %d0\n" n n
         else Printf.sprintf "let v%d = %d\n" n n))

let%expect_test "the cursor steps between hunks and the scope line tracks it" =
  Project.with_temp "review-hunks" @@ fun project ->
  Project.git project [ "init"; "-q" ];
  Project.write project "lib/multi.ml" two_hunk_base;
  Project.git project [ "add"; "-A" ];
  Project.git project [ "commit"; "-q"; "-m"; "baseline" ];
  Project.write project "lib/multi.ml" two_hunk_tip;
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "0/2 reviewed");
  (* The cursor opens on the file; ↓ steps onto the first hunk, then the second,
     the diff scope line naming which (hunk i/n). *)
  Term.send t Keys.down;
  Term.wait t (Screen.has "hunk 1/2");
  print_fact "first hunk selected" (Screen.has "hunk 1/2" (Term.screen t));
  Term.send t Keys.down;
  Term.wait t (Screen.has "hunk 2/2");
  print_fact "second hunk selected" (Screen.has "hunk 2/2" (Term.screen t));
  [%expect {|first hunk selected: true
second hunk selected: true|}]

let%expect_test "t tasks spice to review and submits the agent turn" =
  Project.with_git_fixture "review-task-spice" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  (* [t] closes the review and submits the old /review agent turn (11-review
     §Task spice); the fake provider answers the "Review the current changes."
     prompt so the turn settles. *)
  Provider.with_openai project ~answer:"The changes look correct."
    ~body_contains:[ "Review the current changes" ]
  @@ fun provider ->
  run project ~provider @@ fun t ->
  open_review t;
  (* The review opens over the lone [lib/code.ml] edit — the fake provider's files
     live outside the worktree (Project.scratch), so they never enter the diff —
     and [t] tasks spice; the legend confirms the review is open and [t] available. *)
  Term.wait t (Screen.has "t task spice");
  Term.send t "t";
  (* The screen closes to chat and the prompt lands as user content (the drop). *)
  Term.wait t (Screen.has "Review the current changes.");
  print_fact "review closed to chat"
    (Screen.lacks "t task spice" (Term.screen t));
  print_fact "agent review prompt submitted"
    (Screen.has "Review the current changes." (Term.screen t));
  Term.wait t (Screen.has "The changes look correct.");
  print_fact "agent replied in chat"
    (Screen.has "The changes look correct." (Term.screen t));
  [%expect
    {|review closed to chat: true
agent review prompt submitted: true
agent replied in chat: true|}]

let%expect_test "a malformed CR comment renders as a problem row" =
  Project.with_temp "review-malformed" @@ fun project ->
  Project.git project [ "init"; "-q" ];
  Project.write project "lib/code.ml" "let x = 1\n";
  Project.git project [ "add"; "-A" ];
  Project.git project [ "commit"; "-q"; "-m"; "baseline" ];
  (* A CR marker with no body does not match the grammar, so the scan reports a
     malformed occurrence the nav flags with a [!] problem row (11-review
     §States, §Nav pane). *)
  Project.write project "lib/code.ml" "let x = 1\n(* CR: *)\n";
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "! CR body must not be empty");
  print_fact "malformed CR problem row"
    (Screen.has "! CR body must not be empty" (Term.screen t));
  print_fact "CR source line shown in the diff"
    (Screen.has "(* CR: *)" (Term.screen t));
  [%expect
    {|malformed CR problem row: true
CR source line shown in the diff: true|}]

(* The static goodbye lockup's second row (Theme.lockup), reprinted on exit. *)
let lockup_row = "▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂"

let%expect_test "ctrl+c keeps its arm-to-quit meaning inside review" =
  Project.with_git_fixture "review-ctrlc" @@ fun project ->
  Project.write project "lib/code.ml" sample_code;
  run project @@ fun t ->
  open_review t;
  Term.wait t (Screen.has "0/1 reviewed");
  (* ctrl+c arms then quits on the screen exactly as in chat (11-review
     §Keybindings — not swallowed like the old settings branch). [Term.quit]
     drives the two-stage chord: it presses ctrl+c, waits for the "Press Ctrl+C
     again to exit" notice, then presses again and waits for exit. The shell
     overlays that notice on the screen's bottom row (the app footer is suppressed
     on a screen), so a swallowed chord or a missing notice would hang here. *)
  Term.quit t;
  print_fact "double ctrl+c quits from the review screen"
    (Screen.has lockup_row (Term.screen t));
  [%expect {|double ctrl+c quits from the review screen: true|}]

[%%run_tests "spice.tui-next.review"]
