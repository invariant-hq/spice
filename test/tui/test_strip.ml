(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the status strip and the queued-message affordance
   (doc/ui-design/01-transcript.md §The status strip,
   doc/plans/tui-next-transcript.md). These run real turns, so they drive the
   fake provider: a first turn is held in flight with a server-side delay while a
   second prompt is queued client-side, then observed draining only once the
   first turn settles. Enter is a separate write (an atomic ["text\r"] write is
   swallowed).

   The verbose-strip test is currently RED through no fault of the strip: ctrl+o
   (0x0F) no longer decodes as Ctrl+O on this tree, so [Toggle_expanded] never
   fires and [chat.expanded] stays false. The same regression fails the existing
   [test_transcript.ml] "ctrl+o pins the reasoning ticker open" test; ctrl+c,
   ctrl+r, esc, and plain typing all still work. The verbose row itself renders
   correctly (same helper the passing queued row uses) — it is only unreachable
   until the ctrl+o decode is fixed. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let run ?env ?rows ?cols ?provider project f =
  Term.run ?env ?rows ?cols ?provider project f

(* A submit while a turn is in flight queues client-side (01-transcript.md §The
   status strip): the strip shows [↥ queued · "…" (↑ edits)], the queued prompt
   does NOT reach the provider until the first turn settles, and then it drains
   and runs its own turn. The first turn is held open by a server delay so the
   queued row is observable before it drains. *)
let%expect_test "a submit during a turn queues in the strip and drains on settle" =
  Project.with_temp "next-strip-queue" @@ fun project ->
  let held =
    Provider.delayed_response_line ~delay_ms:2500 ~id:"resp-strip-held"
      ~body_contains:[ "hold" ] ~body_not_contains:[] ~answer:"First turn done."
  in
  let queued =
    Provider.response_line ~id:"resp-strip-queued"
      ~body_contains:[ "changelog" ] ~body_not_contains:[]
      ~answer:"Changelog updated."
  in
  Provider.with_responses project [ held; queued ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "hold the first turn open";
  Term.wait t (Screen.has "❯ hold the first turn open");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t "also update the changelog";
  Term.wait t (Screen.has "also update the changelog");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "↥ queued");
  print_fact "queued row renders in spec form"
    (Screen.has "↥ queued · \"also update the changelog\" (↑ edits)"
       (Term.screen t));
  print_fact "queued prompt has not started while the first turn runs"
    (Screen.lacks "Changelog updated." (Term.screen t));
  print_fact "first turn still in flight while the prompt is queued"
    (Screen.has "esc to interrupt" (Term.screen t));
  Term.wait t (fun s ->
      Screen.has "Changelog updated." s && Screen.has "? for shortcuts" s);
  print_fact "queued prompt ran once the first turn settled"
    (Screen.has "Changelog updated." (Term.screen t));
  print_fact "queued row cleared once it drained"
    (Screen.lacks "↥ queued" (Term.screen t));
  [%expect
    {|
    queued row renders in spec form: true
    queued prompt has not started while the first turn runs: true
    first turn still in flight while the prompt is queued: true
    queued prompt ran once the first turn settled: true
    queued row cleared once it drained: true|}]

(* [↑] on an empty composer edits the queue (01-transcript.md §The status strip,
   revised 2026-07-08): with the composer empty and a turn in flight, [↑] pops the
   newest queued prompt back into the composer — the strip row clears, the text
   returns for editing, and the turn is NOT interrupted (esc never touches the
   queue; [↑] is the queue's key). The first turn is held open so the queued
   prompt never drains before [↑] reaches it. *)
let%expect_test "up-arrow pops the queued prompt back into the composer" =
  Project.with_temp "next-strip-up" @@ fun project ->
  let held =
    Provider.delayed_response_line ~delay_ms:4000 ~id:"resp-strip-up-held"
      ~body_contains:[ "hold" ] ~body_not_contains:[] ~answer:"First turn done."
  in
  Provider.with_responses project [ held ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "hold the turn open for edits";
  Term.wait t (Screen.has "❯ hold the turn open for edits");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t "also update the changelog";
  Term.wait t (Screen.has "also update the changelog");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "↥ queued");
  print_fact "queued row shown before up-arrow"
    (Screen.has "↥ queued" (Term.screen t));
  Term.send t Keys.up;
  Term.wait t (Screen.lacks "↥ queued");
  print_fact "up-arrow cleared the queued row from the strip"
    (Screen.lacks "↥ queued" (Term.screen t));
  print_fact "the prompt returned to the composer for editing"
    (Screen.has "❯ also update the changelog" (Term.screen t));
  print_fact "up-arrow edited the queue rather than interrupting the turn"
    (Screen.has "esc to interrupt" (Term.screen t));
  [%expect
    {|
    queued row shown before up-arrow: true
    up-arrow cleared the queued row from the strip: true
    the prompt returned to the composer for editing: true
    up-arrow edited the queue rather than interrupting the turn: true|}]

(* Interrupt-then-queued-correction-sends is the committed fast path
   (01-transcript.md §The status strip, revised 2026-07-08): with a correction
   queued behind a wrong-direction turn, esc interrupts the turn in one gesture
   (never touching the queue), and the queued correction then drains and runs on
   the interrupted settle. The first response is held so the turn can be caught in
   flight and interrupted; the queued prompt has its own scripted response. *)
let%expect_test "a queued correction sends after the turn is interrupted" =
  Project.with_temp "next-strip-interrupt-queue" @@ fun project ->
  let held =
    Provider.delayed_response_line ~delay_ms:4000 ~id:"resp-strip-iq-held"
      ~body_contains:[ "wrong" ] ~body_not_contains:[]
      ~answer:"This wrong-direction answer is interrupted."
  in
  let correction =
    Provider.response_line ~id:"resp-strip-iq-correction"
      ~body_contains:[ "changelog" ] ~body_not_contains:[]
      ~answer:"Changelog updated after the interrupt."
  in
  Provider.with_responses project [ held; correction ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "go in the wrong direction";
  Term.wait t (Screen.has "❯ go in the wrong direction");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t "also update the changelog";
  Term.wait t (Screen.has "also update the changelog");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "↥ queued");
  (* First esc arms the interrupt; the queue is untouched — the row stays. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  print_fact "mid-stream esc did not touch the queue"
    (Screen.has "↥ queued" (Term.screen t));
  (* Second esc fires the interrupt. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Interrupted");
  print_fact "the turn was interrupted"
    (Screen.has "◌ Interrupted — tell spice what to do differently."
       (Term.screen t));
  Term.wait t (fun s ->
      Screen.has "Changelog updated after the interrupt." s
      && Screen.has "? for shortcuts" s);
  print_fact "the queued correction sent after the interrupt"
    (Screen.has "Changelog updated after the interrupt." (Term.screen t));
  print_fact "queued row cleared once the correction drained"
    (Screen.lacks "↥ queued" (Term.screen t));
  print_fact "the wrong-direction answer never rendered"
    (Screen.lacks "This wrong-direction answer is interrupted." (Term.screen t));
  [%expect
    {|
    mid-stream esc did not touch the queue: true
    the turn was interrupted: true
    the queued correction sent after the interrupt: true
    queued row cleared once the correction drained: true
    the wrong-direction answer never rendered: true|}]

(* The ctrl+o verbose lens announces itself only in the strip (01-transcript.md
   §Disclosure & verbose): with the turn settled, ctrl+o raises the
   [◎ verbose ctrl+o closes] warning row and a second ctrl+o clears it. *)
let%expect_test "ctrl+o raises and clears the verbose strip row" =
  Project.with_temp "next-strip-verbose" @@ fun project ->
  let answer = "A plain settled answer." in
  Provider.with_openai project ~answer ~body_contains:[ "plain" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "give me a plain answer";
  Term.wait t (Screen.has "❯ give me a plain answer");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has answer s && Screen.has "? for shortcuts" s);
  print_fact "no verbose row before ctrl+o"
    (Screen.lacks "verbose ctrl+o closes" (Term.screen t));
  Term.send t Keys.ctrl_o;
  Term.wait t (Screen.has "verbose ctrl+o closes");
  print_fact "ctrl+o raises the verbose row"
    (Screen.has "◎ verbose ctrl+o closes" (Term.screen t));
  Term.send t Keys.ctrl_o;
  Term.wait t (Screen.lacks "verbose ctrl+o closes");
  print_fact "second ctrl+o clears the verbose row"
    (Screen.lacks "verbose ctrl+o closes" (Term.screen t));
  [%expect
    {|
    no verbose row before ctrl+o: true
    ctrl+o raises the verbose row: true
    second ctrl+o clears the verbose row: true|}]

[%%run_tests "spice.tui-next.strip"]
