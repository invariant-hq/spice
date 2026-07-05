(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Liveness and motion for the home screen (12-home.md §Principle 5, 08-brand.md
   §Motion). The home reflects the workspace as it changes — dune connecting,
   worktree edits moving the counts — and the lockup animates until the first
   keystroke. These are the cases that depend on real time passing, so they live
   apart from the static goldens; every observation is still a [Term.wait] on a
   screen predicate, never a wall-clock sleep. *)

open Tui_harness

let print_fact = Util.print_fact

(* The home under test is the hidden [tui-next] subcommand. *)
let run ?env ?rows ?cols project f =
  Term.run ?env ?rows ?cols project f

(* A mid-pour mound (08-brand.md §Motion): the mound region reads [▂▄▄▄▂] only
   partway through a pour, never at rest. It is displayed only by the animation
   loop — reduced motion never shows it, and the static lockup rests at [▂▄▆▄▂].
   Detected on the reconstructed screen, not the raw byte stream: Mosaic diffs
   cell by cell, so a frame emits only the changed glyphs, never the contiguous
   string. *)
let pouring_mound = "▂▄▄▄▂"

(* The static lockup's second row, whole — the resting heap [▂▄▆▄▂] with the
   wordmark. Present at rest, during the pour's hold, and after a freeze. *)
let static_row2 = "▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂"

(* Liveness — dune flip (the requirement): boot idle with dune disconnected, then
   start a real external watch and wait for the workspace block to reflect the
   connection. The dune row always leads the block, carrying the state text. Only
   connectivity
   flips here: the harness builds temp projects with the repo's dune-managed
   toolchain, not on PATH for a bare fixture, so the external [dune --watch]
   connects but cannot compile — no terminal build verdict is latched, and the
   row settles at [dune ✓ · build unknown]. The glyph tracks connectivity only,
   so both the row and the footer flip [✗] → [✓] with an unknown build verdict
   (04-header-footer.md §7, 12-home.md §Degraded — ✗ means disconnected, nothing
   else). The waits key on the state text, which is unambiguous — "connected" is
   a substring of "disconnected", but "build unknown" and "diagnostics" are not. *)
let%expect_test "dune flip: disconnected to connected" =
  Project.with_git_fixture "home-dune-flip" @@ fun project ->
  Project.write project "lib/code.ml" "let alpha = 1\nlet beta = 20\n";
  run project ~env:[ ("SPICE_REDUCED_MOTION", "1") ] ~rows:24 @@ fun t ->
  Term.wait t (Screen.has "diagnostics unavailable");
  print_fact "starts disconnected"
    (Screen.has "✗ · diagnostics unavailable" (Term.screen t));
  print_fact "footer starts ✗" (Screen.has "dune: ✗" (Term.screen t));
  Project.with_external_dune_watch project @@ fun () ->
  Term.wait ~deadline:40.0 t (Screen.has "build unknown");
  print_fact "workspace row flips to connected"
    (Screen.has "✓ · build unknown" (Term.screen t));
  print_fact "no longer disconnected"
    (Screen.lacks "diagnostics unavailable" (Term.screen t));
  print_fact "footer flips to ✓ on connection"
    (Screen.has "dune: ✓" (Term.screen t)
    && Screen.lacks "dune: ✗" (Term.screen t));
  [%expect
    {|starts disconnected: true
footer starts ✗: true
workspace row flips to connected: true
no longer disconnected: true
footer flips to ✓ on connection: true|}]

(* Liveness — worktree counts move: at idle, a further edit lands on a later
   brief tick and the workspace block's worktree row climbs from one file to two.
   Run at 24 rows so the worktree row is not shed. *)
let%expect_test "worktree counts move on edit" =
  Project.with_git_fixture "home-worktree-live" @@ fun project ->
  Project.write project "lib/code.ml"
    "let alpha = 1\nlet beta = 20\nlet gamma = 3\n";
  run project ~env:[ ("SPICE_REDUCED_MOTION", "1") ] ~rows:24 @@ fun t ->
  Term.wait t (Screen.has "1 file changed");
  print_fact "one file changed at launch"
    (Screen.has "1 file changed" (Term.screen t));
  Project.write project "notes.txt" "edited\n";
  Term.wait ~deadline:15.0 t (Screen.has "2 files changed");
  print_fact "count climbs to two files"
    (Screen.has "2 files changed" (Term.screen t));
  [%expect {|one file changed at launch: true
count climbs to two files: true|}]

(* Motion: without reduced motion the lockup pours in full and loops — a mid-pour
   mound proves the animation runs, the settled heap proves it reaches rest, and a
   mid-pour mound *again* proves the pour cycles rather than playing once
   (08-brand.md §Motion). The first printable key freezes it: the mound rests at
   its static form and never pours again (12-home.md §Liveness). The companion is
   the reduced-motion contrast below, where the frame timer is never scheduled so
   the pouring mound is never displayed at all. *)
let%expect_test "lockup pours, loops, then freezes on keystroke" =
  Project.with_temp "home-motion" @@ fun project ->
  run project ~rows:24 @@ fun t ->
  (* Each wait is an await on a state the loop passes through, never a re-read
     that would race the next frame; a timeout means the animation stalled. *)
  Term.wait t (Screen.has pouring_mound);
  Term.wait t (Screen.has static_row2);
  Term.wait t (Screen.has pouring_mound);
  Term.send t "x";
  Term.wait t (Screen.has "❯ x");
  print_fact "static lockup after keystroke"
    (Screen.has static_row2 (Term.screen t));
  print_fact "no longer pouring after freeze"
    (Screen.lacks pouring_mound (Term.screen t));
  [%expect
    {|static lockup after keystroke: true
no longer pouring after freeze: true|}]

let%expect_test "reduced motion is static: no pour frame" =
  Project.with_temp "home-static" @@ fun project ->
  run project ~env:[ ("SPICE_REDUCED_MOTION", "1") ] ~rows:24 @@ fun t ->
  Term.wait t (Screen.has "message spice");
  print_fact "static lockup rendered" (Screen.has static_row2 (Term.screen t));
  (* Structurally guaranteed: Static never drives the pour, so the timer that
     would show a mid-pour mound is never scheduled. *)
  print_fact "no pour frame displayed"
    (Screen.lacks pouring_mound (Term.screen t));
  [%expect {|static lockup rendered: true
no pour frame displayed: true|}]

[%%run_tests "spice.tui-next.home.live"]
