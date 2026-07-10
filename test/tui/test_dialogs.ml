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
     otherwise). The dialog frame and wire assertion are the observable contract;
     this test does not duplicate the post-resume frame coverage. *)
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
04 |   Run a shell command?
05 |
06 |   $ 'echo' 'recorded'
07 |   in $PROJECT/.
08 |
09 | ❯ 1. Yes, run it once
10 |   2. Yes, don't ask again for this command this session
11 |   3. No, and tell Spice what to do differently
12 |   4. Yes, always allow echo
13 |      saves for this session — press s to change
14 |
15 |   1-4 choose · enter confirm · s scope · esc deny with feedback
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
04 |   Run a shell command?
05 |
06 |   $ 'echo' 'recorded'
07 |   in $PROJECT/.
08 |
09 |   1. Yes, run it once
10 |   2. Yes, don't ask again for this command this session
11 | ❯ 3. No, and tell Spice what to do differently
12 |   4. Yes, always allow echo
13 |      saves for this session — press s to change
14 |
15 |   1-4 choose · enter confirm · s scope · esc deny with feedback
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
     the command never ran. The borrow frame and wire assertion prove the deny.
  *)
  Tui.keys t "use a stub instead";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* Always allow: a shell call whose argv has a command family ("git commit")
   offers a fourth option that saves a durable rule over that family. The scope
   line defaults to this session and [s] cycles it to user (the only two scopes:
   a workspace file never originates permission authority). Picking it at user
   scope grants the blocked call for the session AND installs the family rule, so
   a later DISTINCT [git commit] runs with no prompt (the turn reaches its resume
   without a second dialog), and the rule text lands in the outside-workspace
   user config. *)
let%expect_test "always allow saves a family rule and silences the family" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "always test" ] ~id:"resp-aa-1"
        ~call_id:"call-aa1" ~name:"shell"
        ~arguments:{|{"command":"git commit -m first"}|} ();
      Provider_script.tool_call
        ~expect:[ "function_call_output"; "call-aa1" ]
        ~id:"resp-aa-2" ~call_id:"call-aa2" ~name:"shell"
        ~arguments:{|{"command":"git commit -m second"}|} ();
      resume
        ~expect:[ "function_call_output"; "call-aa2" ]
        ~id:"resp-aa-3" "Both commits attempted.";
    ]
  in
  Tui.run ~name:"dialog-perm-always" ~provider:script @@ fun t ->
  open_dialog t "always test";
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    permission
03 |
04 |   Run a shell command?
05 |
06 |   $ 'git' 'commit' '-m' 'first'
07 |   in $PROJECT/.
08 |
09 | ❯ 1. Yes, run it once
10 |   2. Yes, don't ask again for this command this session
11 |   3. No, and tell Spice what to do differently
12 |   4. Yes, always allow git commit
13 |      saves for this session — press s to change
14 |
15 |   1-4 choose · enter confirm · s scope · esc deny with feedback
16 |
17 |
18 |
19 |
20 |
21 |
22 |
23 |
24 ||}];
  (* Cycle the always-allow scope from this session to user, then always-allow
     with [4]. The grant proceeds the first commit; the SECOND distinct commit is
     decided under the installed family rule with no prompt, so the turn reaches
     its resume request without a second dialog opening. *)
  Tui.keys t "s";
  Tui.settle t;
  Tui.keys t "4";
  ignore (Tui.await_request t 3 : string);
  Tui.release t "fin";
  Tui.settle t;
  let user_config =
    Project.scratch (Tui.project t) "config/spice/config.json"
  in
  let contents =
    if Sys.file_exists user_config then Project.read_path user_config else ""
  in
  print_string
    (if
       Screen.contains contents "argv-prefix"
       && Screen.contains contents "commit"
     then "rule saved to user config"
     else "MISSING RULE >>>" ^ contents ^ "<<<");
  [%expect {| rule saved to user config |}]

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
10 |   2. approve + ⏵⏵ accept edits
11 |   3. adjust — tell the model what to change
12 |   4. keep planning
13 |
14 |   1-4 choose · enter confirm · ctrl+o expand · esc keep planning
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
  Tui.keys t "1";
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

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
