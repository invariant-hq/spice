(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The status strip and the queued-message affordance (doc/ui-design/
   01-transcript.md §The status strip), re-expressed as full-frame goldens. A
   first turn is held in flight on a gate while a second prompt is queued
   client-side, then observed draining only once the first turn settles — the old
   pty suite's server-side delay becomes a gate. The interrupt-then-correction
   fast path needs the first turn held while the correction is served, so it runs
   the provider UNORDERED (a held gate must not block the correction's turn).

   The ctrl+o verbose-lens DECODE is pinned in test_input (the 0x0F
   regression guard); here it is the raise→clear toggle of the [◎ verbose] strip
   row. *)

(* {2 Queue and drain} *)

(* A submit while a turn is in flight queues client-side: the strip shows
   [↥ queued · "…" (↑ edits)], the queued prompt does NOT reach the provider until
   the first turn settles, and then it drains and runs its own turn. The first turn
   is held so the queued row is observable before it drains. *)
let%expect_test
    "a submit during a turn queues in the strip and drains on settle" =
  let script =
    [
      Provider.message ~expect:[ "hold" ] ~gate:"held" ~id:"resp-1"
        "First turn done.";
      Provider.message ~expect:[ "changelog" ] ~id:"resp-2" "Changelog updated.";
    ]
  in
  Tui.run ~name:"strip-queue" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "hold the first turn open";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.keys t "also update the changelog";
  Tui.enter t;
  Tui.settle t;
  (* Queued: the first turn is in flight, the queued row shows, the queued prompt
     has not reached the provider. (The composer retains the queued text rather
     than clearing to the placeholder — the same composer-reset product bug
     test_session flags; goldened as-is.) *)
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hold the first turn open
07 |
08 | ⠋ Working… (0s · esc to interrupt)
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
20 |   ↥ queued · "also update the changelog" (↑ edits)
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ also update the changelog
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗       ? for shortcuts|}];
  (* Release the first turn: it settles, the queue drains, the second turn runs. *)
  Tui.release t "held";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hold the first turn open
07 |
08 | ⏺ First turn done.
09 |
10 | ❯ also update the changelog
11 |
12 | ⏺ Changelog updated.
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ also update the changelog
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗       ? for shortcuts|}]

(* {2 Edit the queue} *)

(* [↑] on an empty composer edits the queue: with the composer empty and a turn in
   flight, [↑] pops the newest queued prompt back into the composer — the strip row
   clears, the text returns for editing, and the turn is NOT interrupted ([↑] is
   the queue's key, esc never touches it). The first turn is held so the queued
   prompt never drains before [↑] reaches it. *)
let%expect_test "up-arrow pops the queued prompt back into the composer" =
  let script =
    [
      Provider.message ~expect:[ "hold" ] ~gate:"held" ~id:"resp-1"
        "First turn done.";
    ]
  in
  Tui.run ~name:"strip-up" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "hold the turn open for edits";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.keys t "also update the changelog";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hold the turn open for edits
07 |
08 | ⠋ Working… (0s · esc to interrupt)
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
20 |   ↥ queued · "also update the changelog" (↑ edits)
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ also update the changelog
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}];
  (* [↑] pops the queued prompt back; the strip clears, the turn keeps running. *)
  Tui.keys t Keys.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hold the turn open for edits
07 |
08 | ⠋ Working… (0s · esc to interrupt)
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
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ also update the changelog
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

(* {2 Interrupt then correction} *)

(* Interrupt-then-queued-correction-sends is the committed fast path: with a
   correction queued behind a wrong-direction turn, esc interrupts the turn (never
   touching the queue), and the queued correction then drains and runs on the
   interrupted settle. The first response is held (never released → the third esc
   FORCES the interrupt); the correction has its own gate, released to settle it
   deterministically. Served unordered so the held first turn does not block the
   correction's turn. *)
let%expect_test "a queued correction sends after the turn is interrupted" =
  let script =
    [
      Provider.message ~expect:[ "wrong" ] ~gate:"held" ~id:"resp-1"
        "This wrong-direction answer is interrupted.";
      Provider.message ~expect:[ "changelog" ] ~gate:"correction" ~id:"resp-2"
        "Changelog updated after the interrupt.";
    ]
  in
  Tui.run ~name:"strip-interrupt-queue" ~unordered:true ~provider:script
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "go in the wrong direction";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.keys t "also update the changelog";
  Tui.enter t;
  Tui.settle t;
  (* First esc arms the interrupt; the queue is untouched — the row stays. *)
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ go in the wrong direction
07 |
08 | ⠋ Working… (0s · esc to interrupt)
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
20 |   ↥ queued · "also update the changelog" (↑ edits)
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ also update the changelog
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   Press Esc again to interrupt|}];
  (* Second esc fires the cooperative interrupt (Interrupting…); third forces it,
     the turn settles Interrupted, and the queued correction drains as its own
     turn (held on its gate, then released to settle). *)
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.keys t Keys.escape;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "correction";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ go in the wrong direction
07 |
08 | ◌ Interrupted — tell spice what to do differently.
09 |
10 | ❯ also update the changelog
11 |
12 | ⏺ Changelog updated after the interrupt.
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ also update the changelog
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* {2 The verbose lens toggle} *)

(* ctrl+o raises the [◎ verbose ctrl+o closes] strip row and a second ctrl+o
   clears it. (The 0x0F decode itself is the regression guard in test_input; this
   is the raise→clear toggle test_input does not exercise.) *)
let%expect_test "ctrl+o raises then clears the verbose strip row" =
  let script =
    [
      Provider.message ~expect:[ "plain" ] ~gate:"fin" ~id:"resp-1"
        "A plain settled answer.";
    ]
  in
  Tui.run ~name:"strip-verbose" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "give me a plain answer";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  (* ctrl+o raises the verbose row. *)
  Tui.keys t Keys.ctrl_o;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ give me a plain answer
07 |
08 | ⏺ A plain settled answer.
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
20 |   ◎ verbose ctrl+o closes
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}];
  (* A second ctrl+o clears it. *)
  Tui.keys t Keys.ctrl_o;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ give me a plain answer
07 |
08 | ⏺ A plain settled answer.
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
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

[%%run_tests "spice.tui.strip"]
