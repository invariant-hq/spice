(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The mid-turn decision dialogs (doc/ui-design): a model turn that calls
   [ask_user] opens a question dialog, and one that calls [shell] under the
   ask-first posture opens a permission dialog. Both are driven through the real
   turn pipeline on suite-port-3's [Provider.tool_call] wire — the provider emits
   a [function_call], the app runs the tool (or shows its dialog), and the user's
   decision re-requests with the tool result.

   The DIALOG frame is goldened while the turn is SUSPENDED on the tool call — a
   stable held state. The resolution is goldened while the resume completion is
   HELD on a gate: goldening the post-resume SETTLED frame would race the
   turn-finished socket completion against settle (a harness limitation — the
   socket read is not a tracked perform), so each resolution is proved by the
   resume request (its [~expect] asserts the decision at the wire) plus the stable
   in-flight frame. The plan dialog ([propose_plan]) needs plan mode (a `/plan`
   preamble + a plan resolver) and is deferred — see the coverage report. *)

(* The resume completion after a decision, held on [fin] so its frame is stable. *)
let resume ~expect ~id answer = Provider.message ~expect ~gate:"fin" ~id answer

(* Reach a decision dialog: submit the prompt, sync on the tool-call request, then
   wait for the suspend to reach the screen. The dialog opens only after the
   tool-call RESPONSE is read on the drain fiber the settle probe cannot see, so
   {!Tui.await_suspend} waits for that read to dispatch the dialog before settling
   the stable suspended frame. *)
let open_dialog t prompt =
  Tui.settle t;
  Tui.keys t prompt;
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.await_suspend t

(* {2 Question dialog} *)

(* A structured [ask_user] with two labelled options renders the question and
   both options; the highlighted first option is picked by ↵, and the resume
   request carries that label (asserted at the wire). *)
let%expect_test "the question dialog renders and a pick resumes the turn" =
  let script =
    [
      Provider.tool_call ~expect:[ "which runner" ] ~id:"resp-q-1"
        ~call_id:"call-q" ~name:"ask_user"
        ~arguments:
          {|{"question":"Which test runner should I wire up?","options":[{"label":"dune runtest","description":"the existing runner"},{"label":"alcotest","description":"add a dependency"}]}|}
        ();
      resume
        ~expect:[ "call-q"; "dune runtest" ]
        ~id:"resp-q-2" "Wired up dune runtest.";
    ]
  in
  Tui.run ~name:"dialog-question" ~provider:script @@ fun t ->
  open_dialog t "which runner";
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    question
03 |
04 |   Which test runner should I wire up?
05 |
06 | ❯ 1. dune runtest  the existing runner
07 |   2. alcotest  add a dependency
08 |   3. ✎ type your own answer
09 |
10 |   1-9 choose · enter answer · esc type your own
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
24 ||}];
  (* Pick the highlighted option. The resume request carries "dune runtest",
     asserted at the wire by the resume item's [~expect] (it fails loudly
     otherwise). The resume frame is not goldened — the tool-result render + the
     resume completion race settle (the held frame still transitions through an
     intermediate); the dialog frame + the wire assertion prove the pick. *)
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* Esc on the question dialog borrows the composer for a free-form answer
   (03-composer.md §Borrow): the dialog closes and the composer takes a scoped
   placeholder, no turn resumed yet. *)
let%expect_test "esc on the question dialog borrows the composer" =
  let script =
    [
      Provider.tool_call ~expect:[ "which runner" ] ~id:"resp-qe-1"
        ~call_id:"call-qe" ~name:"ask_user"
        ~arguments:
          {|{"question":"Which test runner should I wire up?","options":[{"label":"dune runtest","description":"the existing runner"},{"label":"alcotest","description":"add a dependency"}]}|}
        ();
    ]
  in
  Tui.run ~name:"dialog-question-esc" ~provider:script @@ fun t ->
  open_dialog t "which runner";
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ⋯ Waiting for your answer
02 |
03 |
04 |
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
20 |   Type your answer
21 |
22 | ────────────────────────────────────────────────────────────────────────────────
23 | ❯ type your answer
24 | ────────────────────────────────────────────────────────────────────────────────|}]

(* {2 Permission dialog} *)

(* A [shell] call under the default ask-first posture opens a permission dialog
   naming the command; ↵ approves the highlighted "run it once", the shell runs
   for real, and the resume carries the tool result. *)
let%expect_test "the permission dialog renders and an approve runs the command"
    =
  let script =
    [
      Provider.tool_call ~expect:[ "run it" ] ~id:"resp-p-1" ~call_id:"call-p"
        ~name:"shell" ~arguments:{|{"command":"echo recorded"}|} ();
      resume
        ~expect:[ "function_call_output"; "recorded" ]
        ~id:"resp-p-2" "Ran the command.";
    ]
  in
  Tui.run ~name:"dialog-perm-allow" ~provider:script @@ fun t ->
  open_dialog t "run it";
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    permission
03 |
04 |   Run a shell command?
05 |
06 |   $ 'echo' 'recorded'
07 |   in $PROJECT/.
08 |
09 | ❯ 1. Yes, run it once
10 |   2. Yes, don't ask again for this command this session
11 |   3. No, and tell Spice what to do differently
12 |
13 |   1/2/3 choose · enter confirm · esc deny with feedback
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
24 ||}];
  (* Approve the highlighted first option: the shell runs and the resume request
     carries its output ("recorded"), asserted at the wire — proof the command
     actually ran (distinct from the deny path below). The resume frame is not
     goldened (it races settle); the dialog frame + the wire assertion suffice. *)
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* Denying the shell call: selecting the third option ("No, and tell Spice what
   to do differently") records the refusal and resumes the turn with the denial
   as the tool result — the command never runs. *)
let%expect_test "the permission dialog denies and resumes without running" =
  let script =
    [
      Provider.tool_call ~expect:[ "run it" ] ~id:"resp-pd-1" ~call_id:"call-pd"
        ~name:"shell" ~arguments:{|{"command":"echo recorded"}|} ();
      resume
        ~expect:[ "function_call_output"; "use a stub instead" ]
        ~id:"resp-pd-2" "Understood, I will not run it.";
    ]
  in
  Tui.run ~name:"dialog-perm-deny" ~provider:script @@ fun t ->
  open_dialog t "run it";
  (* Move to the third option (deny), settling after each arrow so both register
     (two rapid arrows before one settle can drop one under contention). *)
  Tui.keys t Keys.down;
  Tui.settle t;
  Tui.keys t Keys.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    permission
03 |
04 |   Run a shell command?
05 |
06 |   $ 'echo' 'recorded'
07 |   in $PROJECT/.
08 |
09 |   1. Yes, run it once
10 |   2. Yes, don't ask again for this command this session
11 | ❯ 3. No, and tell Spice what to do differently
12 |
13 |   1/2/3 choose · enter confirm · esc deny with feedback
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
24 ||}];
  (* Confirming the deny borrows the composer for the "what to do differently"
     feedback (like esc); typing it and submitting resumes the turn with the
     denial as the tool result — the command never ran. *)
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ⋯ Waiting for your answer
02 |
03 |
04 |
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
20 |   Denying: Run a shell command?  $ 'echo' 'recorded'
21 |
22 | ────────────────────────────────────────────────────────────────────────────────
23 | ❯ tell Spice what to do differently
24 | ────────────────────────────────────────────────────────────────────────────────|}];
  (* Submit the feedback: the turn resumes with the DENIAL as the tool result —
     the resume request carries "use a stub instead" (asserted at the wire), and
     the command never ran. The resume frame is not goldened (it races settle);
     the borrow frame + the wire assertion prove the deny. *)
  Tui.keys t "use a stub instead";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t
