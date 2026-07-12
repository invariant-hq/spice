(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The mid-turn decision dialogs (doc/ui-design): a model turn that calls
   [ask_user] opens a question dialog, and one that calls [shell] under the
   ask-first posture opens a permission dialog. Both are driven through the real
   turn pipeline through [Provider_script.tool_call] — the provider emits a
   [function_call], the app runs the tool (or shows its dialog), and the user's
   decision re-requests with the tool result.

   The DIALOG frame is goldened while the turn is SUSPENDED on the tool call — a
   stable held state. The resolution is goldened while the resume completion is
   HELD on a gate. Each resolution is proved by the resume request (its [~expect]
   asserts the decision at the wire) plus the stable in-flight frame. *)

(* The resume completion after a decision, held on [fin] so its frame is stable. *)
let resume ~expect ~id answer =
  Provider_script.message ~expect ~gate:"fin" ~id answer

(* Reach a decision dialog: submit the prompt, sync on the tool-call request, then
   wait for the suspend to reach the screen. The composed runtime probe tracks
   the Live drain that reads the tool-call response, so {!Tui.await_suspend}
   settles only after the dialog reaches its stable waiting boundary. *)
let open_dialog t prompt =
  Tui.settle t;
  Tui.keys t prompt;
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.await_suspend t

let enter_plan_mode t =
  Tui.settle t;
  Tui.keys t "/plan";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

let count_occurrences ~affix text =
  let affix_length = String.length affix in
  let rec loop from count =
    if from + affix_length > String.length text then count
    else if String.equal (String.sub text from affix_length) affix then
      loop (from + affix_length) (count + 1)
    else loop (from + 1) count
  in
  loop 0 0

(* {2 Question dialog} *)

(* A structured [ask_user] with two labelled options renders the question and
   both options; the highlighted first option is picked by ↵, and the resume
   request carries that label (asserted at the wire). *)
let%expect_test "the question dialog renders and a pick resumes the turn" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "which runner" ] ~id:"resp-q-1"
        ~call_id:"call-q" ~name:"ask_user"
        ~arguments:
          {|{"question":"Which test runner should I wire up?","options":[{"label":"dune runtest","description":"the existing runner"},{"label":"alcotest","description":"add a dependency"}]}|}
        ();
      resume
        ~expect:[ "call-q"; "alcotest" ]
        ~id:"resp-q-2" "Wired up alcotest.";
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
  (* A digit moves the highlight but does not answer. Enter confirms the visible
     row, and the resume request carries "alcotest" (asserted at the wire). *)
  Tui.keys t "2";
  Tui.settle t;
  Printf.printf "digit selects the question row: %b\n"
    (String.includes ~affix:"❯ 2. alcotest" (Tui.screen t));
  [%expect {| digit selects the question row: true |}];
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* Multi-select keeps digits as toggles. Toggling does not answer on its own;
   Enter submits the accumulated checked set. *)
let%expect_test "multi-select digits toggle before Enter submits" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "which checks" ] ~id:"resp-qm-1"
        ~call_id:"call-qm" ~name:"ask_user"
        ~arguments:
          {|{"question":"Which checks should I run?","options":[{"label":"parser","description":"unit suite"},{"label":"cli","description":"headless suite"}],"multi":true}|}
        ();
      resume ~expect:[ "call-qm"; "parser, cli" ] ~id:"resp-qm-2"
        "Ran both suites.";
    ]
  in
  Tui.run ~name:"dialog-question-multi" ~provider:script @@ fun t ->
  open_dialog t "which checks";
  Tui.keys t "12";
  Tui.settle t;
  let screen = Tui.screen t in
  Printf.printf "digits toggle both rows: %b\n"
    (String.includes ~affix:"[x] 1. parser" screen
    && String.includes ~affix:"[x] 2. cli" screen);
  Printf.printf "question still awaits Enter: %b\n"
    (String.includes ~affix:"Which checks should I run?" screen);
  [%expect
    {|
    digits toggle both rows: true
    question still awaits Enter: true |}];
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
      Provider_script.tool_call ~expect:[ "which runner" ] ~id:"resp-qe-1"
        ~call_id:"call-qe" ~name:"ask_user"
        ~arguments:
          {|{"question":"Which test runner should I wire up?","options":[{"label":"dune runtest","description":"the existing runner"},{"label":"alcotest","description":"add a dependency"}]}|}
        ();
    ]
  in
  Tui.run ~name:"dialog-question-esc" ~provider:script @@ fun t ->
  open_dialog t "which runner";
  Tui.keys t Key.escape;
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
      Provider_script.tool_call ~expect:[ "run it" ] ~id:"resp-p-1"
        ~call_id:"call-p" ~name:"shell"
        ~arguments:{|{"command":"echo recorded"}|} ();
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
04 |   Run this command?
05 |
06 |   $ echo recorded
07 |   in $PROJECT/.
08 |
09 | ❯ 1. Yes, run it once
10 |   2. Yes, allow this command for this conversation
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
     actually ran (distinct from the deny path below). The dialog frame and wire
     assertion are the observable contract. *)
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* A model response may leave several commands waiting for review. A numbered
   shortcut selects within the visible dialog; only Enter confirms that dialog.
   Therefore the common digit-then-Enter sequence may advance by one dialog,
   but cannot spend the Enter on the next, unseen command. *)
let%expect_test "digit then Enter cannot approve a stacked permission dialog" =
  let script =
    [
      Provider_script.tool_calls ~expect:[ "run both" ] ~id:"resp-ps-1"
        ~calls:
          [
            ("call-ps-1", "shell", {|{"command":"printf FIRST"}|});
            ("call-ps-2", "shell", {|{"command":"printf SECOND"}|});
          ]
        ();
      resume
        ~expect:[ "call-ps-1"; "FIRST"; "call-ps-2"; "SECOND" ]
        ~id:"resp-ps-2" "Ran both commands.";
    ]
  in
  Tui.run ~name:"dialog-perm-stacked" ~provider:script @@ fun t ->
  open_dialog t "run both";
  Tui.keys t "2";
  Tui.settle t;
  Printf.printf "digit selects the visible row: %b\n"
    (String.includes ~affix:"❯ 2. Yes" (Tui.screen t));
  [%expect {| digit selects the visible row: true |}];
  Tui.enter t;
  Tui.settle t;
  Printf.printf "second dialog still awaits confirmation: %b\n"
    (String.includes ~affix:"$ printf SECOND" (Tui.screen t));
  [%expect {| second dialog still awaits confirmation: true |}];
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* A follow-up draft may be typed while the provider is still producing the
   tool call. Once the permission modal appears, its digit and confirming Enter
   must be consumed by that modal; the restored draft remains exactly once in
   the composer and never becomes a new request. *)
let%expect_test "permission confirmation cannot submit a restored draft" =
  let draft = "DRAFT-NOT-SENT" in
  let script =
    [
      Provider_script.tool_call ~expect:[ "run it" ] ~gate:"dialog"
        ~id:"resp-pd-1" ~call_id:"call-pd" ~name:"shell"
        ~arguments:{|{"command":"printf recorded"}|} ();
      resume ~expect:[ "call-pd"; "recorded" ] ~id:"resp-pd-2"
        "Command finished.";
      Provider_script.message ~expect:[ draft ] ~gate:"unexpected"
        ~id:"resp-pd-3" "The draft was unexpectedly submitted.";
    ]
  in
  Tui.run ~name:"dialog-perm-draft" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "run it";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.keys t draft;
  Tui.release_response t "dialog";
  Tui.await_suspend t;
  Tui.keys t "1";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  let screen = Tui.screen t in
  Printf.printf "draft remains only in composer: %b\n"
    (count_occurrences ~affix:draft screen = 1);
  Printf.printf "permission turn completed: %b\n"
    (String.includes ~affix:"Command finished." screen);
  [%expect
    {|
    draft remains only in composer: true
    permission turn completed: true |}]

(* A compound shell expression may normalize to several access facts, but it is
   still one model action and therefore one decision. The original expression
   is primary; normalized facts are available behind the details toggle. *)
let%expect_test "a compound command is presented as one atomic action" =
  let command =
    "git status --short && test ! -e .probe-one && test ! -e .probe-two"
  in
  let script =
    [
      Provider_script.tool_call ~expect:[ "inspect workspace" ] ~id:"resp-pa-1"
        ~call_id:"call-pa" ~name:"shell"
        ~arguments:(Printf.sprintf {|{"command":%S}|} command) ();
      resume ~expect:[ "function_call_output" ] ~id:"resp-pa-2"
        "Inspected the workspace.";
    ]
  in
  Tui.run ~name:"dialog-perm-atomic" ~provider:script @@ fun t ->
  open_dialog t "inspect workspace";
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    permission
03 |
04 |   Run this command?
05 |
06 |   $ git status --short && test ! -e .probe-one && test ! -e .probe-two
07 |   in $PROJECT/.
08 |
09 | ❯ 1. Yes, allow once
10 |   2. Yes, allow these accesses for this conversation
11 |   3. No, and tell Spice what to do differently
12 |
13 |   1/2/3 choose · enter confirm · ctrl+o details · esc deny with feedback
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
  Tui.keys t Key.ctrl_o;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ⋯ Waiting for your answer
02 |
03 |
04 |
05 |
06 |
07 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
08 |    permission
09 |
10 |   Run this command?
11 |
12 |   $ git status --short && test ! -e .probe-one && test ! -e .probe-two
13 |   in $PROJECT/.
14 |
15 |   Permission details
16 |   exec 'git' 'status' '--short' in $PROJECT/.
17 |   exec 'test' '!' '-e' '.probe-one' in $PROJECT
18 |   exec 'test' '!' '-e' '.probe-two' in $PROJECT
19 |
20 | ❯ 1. Yes, allow once
21 |   2. Yes, allow these accesses for this conversation
22 |   3. No, and tell Spice what to do differently
23 |
24 |   1/2/3 choose · enter confirm · esc deny with feedback|}];
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
      Provider_script.tool_call ~expect:[ "run it" ] ~id:"resp-pd-1"
        ~call_id:"call-pd" ~name:"shell"
        ~arguments:{|{"command":"echo recorded"}|} ();
      resume
        ~expect:[ "function_call_output"; "use a stub instead" ]
        ~id:"resp-pd-2" "Understood, I will not run it.";
    ]
  in
  Tui.run ~name:"dialog-perm-deny" ~provider:script @@ fun t ->
  open_dialog t "run it";
  (* Move to the third option (deny), settling after each arrow so both register
     (two rapid arrows before one settle can drop one under contention). *)
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    permission
03 |
04 |   Run this command?
05 |
06 |   $ echo recorded
07 |   in $PROJECT/.
08 |
09 |   1. Yes, run it once
10 |   2. Yes, allow this command for this conversation
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
20 |   Denying: Run this command?  echo recorded
21 |
22 | ────────────────────────────────────────────────────────────────────────────────
23 | ❯ tell Spice what to do differently
24 | ────────────────────────────────────────────────────────────────────────────────|}];
  (* Submit the feedback: the turn resumes with the DENIAL as the tool result —
     the resume request carries "use a stub instead" (asserted at the wire), and
     the command never ran. The borrow frame and wire assertion prove the deny.
  *)
  Tui.keys t "use a stub instead";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* A proposed plan is a real host-tool boundary in plan mode. The first option
   approves it, and the next provider request must carry the tool result before
   the turn can resume. *)
let%expect_test "the plan dialog approves and resumes the turn" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "draft a plan" ] ~id:"resp-plan-1"
        ~call_id:"call-plan" ~name:"propose_plan"
        ~arguments:
          {|{"id":"plan-1","title":"Refactor the parser","body":"Split the tokenizer out.\nMake parse return a result."}|}
        ();
      resume ~expect:[ "call-plan" ] ~id:"resp-plan-2"
        "Parser refactor complete.";
    ]
  in
  Tui.run ~name:"dialog-plan-approve" ~provider:script @@ fun t ->
  enter_plan_mode t;
  open_dialog t "draft a plan for the refactor";
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    plan
03 |
04 |   Refactor the parser
05 |
06 |   Split the tokenizer out.
07 |   Make parse return a result.
08 |
09 | ❯ 1. approve
10 |   2. adjust — tell the model what to change
11 |   3. keep planning
12 |
13 |   1-3 choose · enter confirm · ctrl+o expand · esc keep planning
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
  Tui.keys t Key.down;
  Tui.keys t "1";
  Tui.settle t;
  Printf.printf "digit selects the plan row: %b\n"
    (String.includes ~affix:"❯ 1. approve" (Tui.screen t));
  [%expect {| digit selects the plan row: true |}];
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* This is the modal-boundary form of the draft leak: the model's plan arrives
   after the user has already started a follow-up. The plan's digit and Enter
   resolve only the proposal, leaving that draft unsubmitted in the composer. *)
let%expect_test "plan confirmation cannot submit a restored draft" =
  let draft = "PLAN-DRAFT-NOT-SENT" in
  let script =
    [
      Provider_script.tool_call ~expect:[ "draft a plan" ] ~gate:"dialog"
        ~id:"resp-plan-draft-1" ~call_id:"call-plan-draft"
        ~name:"propose_plan"
        ~arguments:
          {|{"id":"plan-draft","title":"Refactor safely","body":"Keep the public boundary small."}|}
        ();
      resume ~expect:[ "call-plan-draft" ] ~id:"resp-plan-draft-2"
        "Plan accepted.";
      Provider_script.message ~expect:[ draft ] ~gate:"unexpected"
        ~id:"resp-plan-draft-3" "The draft was unexpectedly submitted.";
    ]
  in
  Tui.run ~name:"dialog-plan-draft" ~provider:script @@ fun t ->
  enter_plan_mode t;
  Tui.keys t "draft a plan";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.keys t draft;
  Tui.release_response t "dialog";
  Tui.await_suspend t;
  Tui.keys t "1";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  let screen = Tui.screen t in
  Printf.printf "plan draft remains only in composer: %b\n"
    (count_occurrences ~affix:draft screen = 1);
  Printf.printf "plan turn completed: %b\n"
    (String.includes ~affix:"Plan accepted." screen);
  [%expect
    {|
    plan draft remains only in composer: true
    plan turn completed: true |}]

(* Escape is the safe plan decision: it rejects the proposal, keeps plan mode,
   and resumes the provider without ever emitting an approval. *)
let%expect_test "escape rejects the plan and keeps planning" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "draft a plan" ] ~id:"resp-plan-esc-1"
        ~call_id:"call-plan-esc" ~name:"propose_plan"
        ~arguments:
          {|{"id":"plan-esc","title":"Refactor the parser","body":"Split the tokenizer out.\nMake parse return a result."}|}
        ();
      resume ~expect:[ "call-plan-esc" ] ~id:"resp-plan-esc-2"
        "Revised the plan.";
    ]
  in
  Tui.run ~name:"dialog-plan-reject" ~provider:script @@ fun t ->
  enter_plan_mode t;
  open_dialog t "draft a plan for the refactor";
  Tui.keys t Key.escape;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ draft a plan for the refactor
07 |
08 |   kept planning
09 |
10 | ⏺ Plan
11 |   ⎿  proposed
12 |
13 | ⏺ Revised the plan.
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 |  ⏸ plan ────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]
