(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The /review screen (doc/ui-design/11-review.md), re-expressed as full-frame
   goldens. The screen opens over the worktree diff of a real git repo seeded in
   the temp project ([Project.git_baseline] commits the seed, a later write is the
   diff). Primary entry is the [spice review] subcommand seam [~review:true] (the
   harness wraps [Startup.Launch_review]) — the screen boots straight up and
   esc/close QUITS (no stage behind it). One test opens the in-app way, [/review]
   from
   the home stage, where esc returns to the stage. Marks and the verdict write the
   global workspace review store; CRs write comments into the source. *)

let sample_code = "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 4\n"
let base_code = "let alpha = 1\nlet beta = 2\nlet gamma = 3\nlet delta = 4\n"

(* A committed baseline plus the uncommitted edit the review opens on. *)
let seed_diff project =
  Project.write project "lib/code.ml" base_code;
  Project.write project "notes.txt" "baseline\n";
  Project.git_baseline project;
  Project.write project "lib/code.ml" sample_code

(* The review store uses opaque workspace and review keys, so scan the isolated
   data home for the persisted word (a sanctioned narrow non-visual fact). *)
let reviews_store_has project needle =
  let rec scan path =
    if Sys.is_directory path then
      Sys.readdir path
      |> Array.exists (fun name -> scan (Filename.concat path name))
    else Screen.contains (Project.read_path path) needle
  in
  let dir = Project.data project "workspaces" in
  Sys.file_exists dir && scan dir

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
  fact "verdict persisted to global workspace state"
    (reviews_store_has (Tui.project t) "approved");
  [%expect {| verdict persisted to global workspace state: true |}]

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
03 | ! $PROJECT is not inside a git worktree: fatal:
04 | not a git repository (or any of the parent directories): .git
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
  Tui.keys t Key.escape;
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

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
  Tui.keys t Key.tab;
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

let source_has t needle =
  Screen.contains (Project.read (Tui.project t) "lib/code.ml") needle

(* CR composition and resolution mutate the source through the real review Git
   adapter. A bare body beginning with CR remains body text rather than being
   misparsed as a second marker. *)
let%expect_test "CR add and resolve round trip through the source" =
  Tui.run ~name:"review-cr-lifecycle" ~review:true ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t "c";
  Tui.settle t;
  Tui.keys t "alice: CRDT state needs a note";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · unreviewed · +2 −1
04 |  ❯ [ ] code.ml                M │ 1   let alpha = 1
05 |      CR alice: CRDT state needs │ 2   let beta = 2
06 |                                 │ 3 - let gamma = 3
07 |                                 │ 3 + (* CR alice: CRDT state needs a note *)
08 |                                 │ 4 + let gamma = 33
09 |                                 │ 5   let delta = 4
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
24 | CR added|}];
  print_string
    (if source_has t "(* CR alice: CRDT state needs a note *)" then
       "CR written\n"
     else "CR missing\n");
  [%expect {| CR written |}];
  Tui.keys t "n";
  Tui.settle t;
  Tui.keys t "x";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · unreviewed · +2 −1
04 |  ❯ [ ] code.ml                M │ 1   let alpha = 1
05 |      XCR user for alice: CRDT st│ 2   let beta = 2
06 |                                 │ 3 - let gamma = 3
07 |                                 │ 3 + (* XCR user for alice: CRDT state needs a
08 |                                 │ 4 + let gamma = 33
09 |                                 │ 5   let delta = 4
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
24 | CR resolved|}];
  print_string
    (if source_has t "XCR" then "CR resolved\n" else "CR unresolved\n");
  [%expect {| CR resolved |}]

(* Existing CRs can be edited and removed in place. The edit dialog starts from
   the canonical body; replacing its last word changes the source before the
   remove action deletes the occurrence entirely. *)
let%expect_test "CR edit and remove update the source" =
  Tui.run ~name:"review-cr-edit-remove" ~review:true ~seed:(fun project ->
      Project.write project "lib/code.ml" base_code;
      Project.git_baseline project;
      Project.write project "lib/code.ml"
        "let alpha = 1\n\
         let beta = 2\n\
         let gamma = 33\n\
         (* CR: rename gamma *)\n\
         let delta = 4\n")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "n";
  Tui.settle t;
  Tui.keys t "e";
  Tui.settle t;
  Tui.keys t (String.make 5 '\127');
  Tui.keys t "delta";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · unreviewed · +2 −1
04 |  ❯ [ ] code.ml                M │ 1   let alpha = 1
05 |      CR: rename delta           │ 2   let beta = 2
06 |                                 │ 3 - let gamma = 3
07 |                                 │ 3 + let gamma = 33
08 |                                 │ 4 + (* CR: rename delta *)
09 |                                 │ 5   let delta = 4
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
24 | CR updated|}];
  print_string
    (if source_has t "rename delta" then "CR edited\n" else "CR edit missing\n");
  [%expect {| CR edited |}];
  Tui.keys t "n";
  Tui.settle t;
  Tui.keys t "d";
  Tui.settle t;
  print_string
    (if source_has t "CR:" then "CR still present\n" else "CR removed\n");
  [%expect {| CR removed |}]

let seed_deletion project =
  Project.write project "lib/code.ml"
    "let f () =\n  let kept = 1 in\n  let removed = 2 in\n  kept\n";
  Project.git_baseline project;
  Project.write project "lib/code.ml" "let f () =\n  let kept = 1 in\n  kept\n"

(* The diff cursor steps from the removed to the added side, and a CR anchored
   on a removed line or pure-deletion hunk lands at the surviving indentation. *)
let%expect_test "line and deletion-hunk comments keep their source anchor" =
  ( Tui.run ~name:"review-line-comment" ~review:true ~seed:seed_deletion
  @@ fun t ->
    Tui.settle t;
    Tui.keys t Key.tab;
    Tui.settle t;
    Tui.keys t "c";
    Tui.settle t;
    Tui.print t;
    [%expect
      {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · unreviewed · +0 −1
04 |  ❯ [ ] code.ml                M │ 1   let f () =
05 |                                 │ 2     let kept = 1 in
06 |                                 │ 3 -   let removed = 2 in
07 |                                 │ 3     kept
08 |                                 │
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
24 | enter add CR · esc cancel|}];
    Tui.keys t "fix: keep this";
    Tui.enter t;
    Tui.settle t;
    print_string
      (if source_has t "\n  (* CR fix: keep this *)\n" then
         "line comment anchored\n"
       else "line comment misplaced\n");
    [%expect {| line comment anchored |}] );
  Tui.run ~name:"review-hunk-comment" ~review:true ~seed:seed_deletion
  @@ fun t ->
  Tui.settle t;
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.keys t "c";
  Tui.settle t;
  Tui.keys t "fix: keep this";
  Tui.enter t;
  Tui.settle t;
  print_string
    (if source_has t "\n  (* CR fix: keep this *)\n  kept\n" then
       "hunk comment anchored\n"
     else "hunk comment misplaced\n");
  [%expect {| hunk comment anchored |}]

(* A real fswatch event debounces on virtual time, reloads the feature, and
   visibly stales an approval bound to the previous content. *)
let%expect_test "live refresh adds units and stales an approval" =
  Tui.run ~name:"review-live-refresh" ~review:true ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t " ";
  Tui.settle t;
  Tui.keys t "a";
  Tui.settle t;
  Tui.await_review_refresh t (fun () ->
      Project.write (Tui.project t) "notes.txt" "baseline\nreviewed live\n");
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                           1/2 reviewed · approved · stale
03 |  ▾ lib                          │lib/code.ml · reviewed · +1 −1
04 |  ❯ [✓] code.ml                M │  1   let alpha = 1
05 |    [ ] notes.txt              M │  2   let beta = 2
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
24 | refreshed · 1 new unit · verdict stale|}]

(* Space is a true toggle on a completed unit: a second press clears its mark
   and returns progress to zero. *)
let%expect_test "space on a reviewed unit unmarks it" =
  Tui.run ~name:"review-unmark" ~review:true ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t " ";
  Tui.settle t;
  Tui.keys t " ";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · reviewed · +1 −1
04 |  ❯ [ ] code.ml                M │  1   let alpha = 1
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
24 | tab focus diff · space mark · enter open · c comment · a approve · t task spice|}]

let two_hunk_base =
  String.concat ""
    (List.init 30 (fun i -> Printf.sprintf "let v%d = %d\n" (i + 1) (i + 1)))

let two_hunk_tip =
  String.concat ""
    (List.init 30 (fun i ->
         let n = i + 1 in
         if n = 2 || n = 29 then Printf.sprintf "let v%d = %d0\n" n n
         else Printf.sprintf "let v%d = %d\n" n n))

(* Nav down walks the two hunk scopes and updates the diff scope line. *)
let%expect_test "the cursor steps between hunks" =
  Tui.run ~name:"review-hunks" ~review:true ~seed:(fun project ->
      Project.write project "lib/code.ml" two_hunk_base;
      Project.git_baseline project;
      Project.write project "lib/code.ml" two_hunk_tip)
  @@ fun t ->
  Tui.settle t;
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/2 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · hunk 1/2 · unreviewed · +2 −2
04 |  ❯ [ ] code.ml                M │❯  1   let v1 = 1
05 |                                 │   2 - let v2 = 2
06 |                                 │   2 + let v2 = 20
07 |                                 │   3   let v3 = 3
08 |                                 │   4   let v4 = 4
09 |                                 │   5   let v5 = 5
10 |                                 │   6   let v6 = 6
11 |                                 │   7   let v7 = 7
12 |                                 │   8   let v8 = 8
13 |                                 │   9   let v9 = 9
14 |                                 │  10   let v10 = 10
15 |                                 │  11   let v11 = 11
16 |                                 │  12   let v12 = 12
17 |                                 │  13   let v13 = 13
18 |                                 │  14   let v14 = 14
19 |                                 │ 17   let v17 = 17
20 |                                 │ 18   let v18 = 18
21 |                                 │ 19   let v19 = 19
22 |                                 │
23 |
24 | tab focus diff · space mark · enter open · c comment · a approve · t task spice|}];
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/2 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · hunk 2/2 · unreviewed · +2 −2
04 |  ❯ [ ] code.ml                M │  4   let v4 = 4
05 |                                 │  5   let v5 = 5
06 |                                 │  6   let v6 = 6
07 |                                 │  7   let v7 = 7
08 |                                 │  8   let v8 = 8
09 |                                 │  9   let v9 = 9
10 |                                 │ 10   let v10 = 10
11 |                                 │ 11   let v11 = 11
12 |                                 │ 12   let v12 = 12
13 |                                 │ 13   let v13 = 13
14 |                                 │ 14   let v14 = 14
15 |                                 │❯ 17   let v17 = 17
16 |                                 │  18   let v18 = 18
17 |                                 │  19   let v19 = 19
18 |                                 │  20   let v20 = 20
19 |                                 │  21   let v21 = 21
20 |                                 │  22   let v22 = 22
21 |                                 │  23   let v23 = 23
22 |                                 │
23 |
24 | tab focus diff · space mark · enter open · c comment · a approve · t task spice|}]

(* Task Spice closes the review into chat and submits the agent-review prompt as
   a real turn. *)
let%expect_test "task spice submits the agent review turn" =
  let script =
    [
      Provider_script.message
        ~expect:[ "Review the current changes" ]
        ~gate:"fin" ~id:"resp-review-task" "The changes look correct.";
    ]
  in
  Tui.run ~name:"review-task-spice" ~seed:seed_diff ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "/review";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "t";
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ Review the current changes.
07 |
08 | ⏺ The changes look correct.
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
21 |  ⏴ review ──────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

(* Malformed CR syntax is a first-class problem row alongside the source line. *)
let%expect_test "a malformed CR renders as a problem row" =
  Tui.run ~name:"review-malformed" ~review:true ~seed:(fun project ->
      Project.write project "lib/code.ml" "let x = 1\n";
      Project.git_baseline project;
      Project.write project "lib/code.ml" "let x = 1\n(* CR: *)\n")
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ────────────────────────────────────────────────────────────────────────────────
02 | Review  HEAD..worktree                                    0/1 reviewed · pending
03 |  ▾ lib                          │lib/code.ml · unreviewed · +1 −0
04 |  ❯ [ ] code.ml                M │ 1   let x = 1
05 |      ! CR body must not be empty│ 2 + (* CR: *)
06 |                                 │
07 |                                 │
08 |                                 │
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

(* Ctrl+C retains the shell-wide arm-to-quit contract while review suppresses
   the ordinary app footer. *)
let%expect_test "ctrl+c arms and quits from review" =
  Tui.run ~name:"review-ctrl-c" ~review:true ~seed:seed_diff @@ fun t ->
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
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
24 |   Press Ctrl+C again to exit|}];
  Tui.keys t Key.ctrl_c;
  Tui.await_exit t;
  ignore (Tui.outcome t)

[%%run_tests "spice.tui.review"]
