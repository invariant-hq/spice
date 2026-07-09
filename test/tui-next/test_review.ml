(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The /review screen (doc/ui-design/11-review.md), re-expressed as full-frame
   goldens. The screen opens over the worktree diff of a real git repo seeded in
   the temp project ([Project.git_baseline] commits the seed, a later write is the
   diff). Primary entry is the [spice review] subcommand seam [~review:true] (the
   harness wraps [Startup.Launch_review]) — the screen boots straight up and
   esc/close QUITS (no stage behind it). One test opens the in-app way, [/review]
   from
   the home stage, where esc returns to the stage. Marks and the verdict write the
   review store under [.spice/reviews]; CRs write comments into the source. *)

let sample_code = "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 4\n"
let base_code = "let alpha = 1\nlet beta = 2\nlet gamma = 3\nlet delta = 4\n"

(* A committed baseline plus the uncommitted edit the review opens on. *)
let seed_diff project =
  Project.write project "lib/code.ml" base_code;
  Project.write project "notes.txt" "baseline\n";
  Project.git_baseline project;
  Project.write project "lib/code.ml" sample_code

(* The review store the screen persists marks/verdicts to, under
   [.spice/reviews/<key>.json] — the key is a base..tip hash the test does not
   predict, so scan the directory for the persisted word (a non-visual observable,
   the sanctioned narrow fact use). *)
let reviews_store_has project needle =
  let dir = Filename.concat (Project.root project) ".spice/reviews" in
  Sys.file_exists dir
  && Array.exists
       (fun name ->
         Util.contains (Util.read_file (Filename.concat dir name)) needle)
       (Sys.readdir dir)

let fact label b = print_string (Printf.sprintf "%s: %b\n" label b)

(* {2 Marks and the verdict} *)

(* Marking the unit reviewed advances progress to [1/1 reviewed]; [a] approves.
   The frame pins the two-pane layout — nav left, unified diff right — the header
   range and verdict, and the keybinding legend (the screen suppresses the app
   footer). *)
let%expect_test "the review screen marks, approves, and shows the verdict" =
  Tui.run ~name:"review-marks" ~review:true ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t " ";
  Tui.settle t;
  Tui.keys t "a";
  Tui.settle t;
  Tui.print t;
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
  (* The verdict persisted to the review store, not just the screen. *)
  fact "verdict persisted to .spice/reviews"
    (reviews_store_has (Tui.project t) "approved");
  [%expect {| verdict persisted to .spice/reviews: true |}]

(* {2 The empty and error states} *)

(* A clean worktree (the baseline committed, nothing written after) has nothing to
   review: the screen shows the one-line empty state. *)
let%expect_test "a clean worktree shows the empty state" =
  Tui.run ~name:"review-empty" ~review:true ~seed:(fun project ->
      Project.write project "lib/code.ml" sample_code;
      Project.git_baseline project)
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree
03 | esc close
04 |   no changes to review — the worktree matches HEAD
05 |
06 |
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
18 |
19 |
20 |
21 |
22 |
23 |
24 ||}]

(* Outside a git worktree the screen shows the problem line and the esc affordance
   rather than a diff. *)
let%expect_test "the review screen reports a missing repository" =
  Tui.run ~name:"review-no-repo" ~review:true @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review
03 | ! $PROJECT is not inside a git worktree:
04 | fatal: not a git repository (or any of the parent directories): .git
05 | esc close
06 |
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
18 |
19 |
20 |
21 |
22 |
23 |
24 ||}]

(* {2 The in-app entry} *)

(* Opening the review the in-app way — the [/review] command from the home stage —
   and returning with esc. Unlike [~review:true], there is a stage behind it, so
   esc closes the screen back to the home stage rather than quitting. *)
let%expect_test "/review opens from the stage and esc returns to it" =
  Tui.run ~name:"review-command" ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t "/review";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
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
  (* esc closes the screen; the home stage returns (the git fixture's worktree
     block is what the stage shows here, proving it is the stage, not the
     screen). *)
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ message spice
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                    dune       ✗ · diagnostics unavailable
17 |                    account    none — /login to connect
18 |                    worktree   1 file changed · +1 −1 · /review
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · …-next-review-command · gpt-5.5 medium · dune: ✗|}]

(* {2 Help and narrow layout} *)

(* [?] raises the key table over the screen; a second [?] clears it back to the
   review body. *)
let%expect_test "the key table toggles with ?" =
  Tui.run ~name:"review-help" ~review:true ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t "?";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |   tab           switch focus (nav / diff)
04 |   ↑/↓, j/k  move selection / hunk
05 |   ]/[           next / previous hunk (diff)
06 |   enter         focus the diff pane
07 |   space         mark reviewed and advance
08 |   n / p         next / previous CR
09 |   c / e         add / edit CR
10 |   x / d         resolve / remove CR
11 |   a             toggle approved / pending
12 |   t             task spice to review
13 |   ctrl+o        cycle diff context
14 |   ?             toggle this table
15 |   esc           back / close
16 |
17 |
18 |
19 |
20 |
21 |
22 |
23 |
24 | tab focus diff · space mark · enter open · c comment · a approve · t task spice|}];
  Tui.keys t "?";
  Tui.settle t;
  Tui.print t;
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
24 | tab focus diff · space mark · enter open · c comment · a approve · t task spice|}]

(* Below 80 columns the two-pane split collapses to a single full-width pane — the
   focused one (nav on open) — and tab swaps which pane is shown. *)
let%expect_test "below 80 columns the split collapses to one focused pane" =
  Tui.run ~name:"review-narrow" ~size:(70, 24) ~review:true ~seed:seed_diff
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                          0/1 reviewed · pending
03 |  ▾ lib
04 |  ❯ [ ] code.ml                                                      M
05 |
06 |
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
18 |
19 |
20 |
21 |
22 |
23 |
24 | tab focus diff · space mark · enter open · c comment · a approve · t t|}];
  Tui.keys t Keys.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                          0/1 reviewed · pending
03 | lib/code.ml · unreviewed · +1 −1
04 |   1   let alpha = 1
05 |   2   let beta = 2
06 | ❯ 3 - let gamma = 3
07 |   3 + let gamma = 33
08 |   4   let delta = 4
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 |
22 |
23 |
24 | tab focus nav · space mark hunk · c comment · ]/[ hunk · ctrl+o contex|}]

[%%run_tests "spice.tui-next.review"]
