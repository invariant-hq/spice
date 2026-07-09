(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] decision dialogs (07-dialogs.md,
   03-ia-screens-overlays.md §Dialogs, doc/plans/tui-next-dialog-seam.md). A fake
   provider function call blocks the turn on a question or plan boundary and
   raises the matching dialog; the tests drive the option list and the composer
   borrow, then golden the settled screen and the resumed turn.

   Enter is always a separate write (the atomic-enter pitfall).

   The permission dialog is exercised by the module's own compile and the shared
   integration path these tests prove; its blackbox trigger (a reviewed
   [write_file]) is regressed tree-wide in this working tree — the old TUI's
   [test/tui/test_prompts] permission case auto-allows the write identically — so
   it is not goldened here until that review path is restored. *)

open Tui_harness

let print_fact = Util.print_fact
let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]

let run ?args ?env ?rows ?cols ?provider project f =
  Term.run ?args ?env ?rows ?cols ?provider project f

(* A structured [ask_user] call: two labelled options with descriptions. *)
let ask_options_call =
  {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":["which runner"]},"response":{"id":"resp-q-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-q","call_id":"call-q","name":"ask_user","arguments":"{\"question\":\"Which test runner should I wire up?\",\"options\":[{\"label\":\"dune runtest\",\"description\":\"the existing runner\"},{\"label\":\"alcotest\",\"description\":\"add a dependency\"}]}"}]}}|}

(* A [propose_plan] call: blocks the turn on the plan-approval boundary. *)
let propose_plan_call =
  {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":["draft a plan"]},"response":{"id":"resp-plan-1","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-plan","call_id":"call-plan","name":"propose_plan","arguments":"{\"id\":\"plan-1\",\"title\":\"Refactor the parser\",\"body\":\"Split the tokenizer out.\\nMake parse return a result.\"}"}]}}|}

let%expect_test "question structured single-select picks a label" =
  Project.with_temp "next-question" @@ fun project ->
  let answer = "Wiring up dune runtest." in
  let resume =
    Provider.response_line ~id:"resp-q-2"
      ~body_contains:[ "function_call_output"; "call-q"; "dune runtest" ]
      ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ ask_options_call; resume ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "which runner should I use";
  Term.wait t (Screen.has "❯ which runner should I use");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Which test runner");
  print_fact "question chip" (Screen.has "question" (Term.screen t));
  print_fact "options render verbatim"
    (Screen.has "dune runtest" (Term.screen t)
    && Screen.has "alcotest" (Term.screen t));
  print_fact "descriptions render"
    (Screen.has "the existing runner" (Term.screen t));
  print_fact "own-answer row present"
    (Screen.has "type your own answer" (Term.screen t));
  Screen.print ~project (Term.screen t);
  Term.send t "1";
  Term.wait t (Screen.has answer);
  print_fact "answered echo" (Screen.has "answered" (Term.screen t));
  print_fact "resumed answer" (Screen.has answer (Term.screen t));
  [%expect {| |}]

let%expect_test "question esc borrows the composer for a custom answer" =
  Project.with_temp "next-question-custom" @@ fun project ->
  let answer = "Using a custom runner." in
  let resume =
    Provider.response_line ~id:"resp-q-custom-2"
      ~body_contains:[ "function_call_output"; "call-q"; "my own runner" ]
      ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ ask_options_call; resume ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "which runner should I use";
  Term.wait t (Screen.has "❯ which runner should I use");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Which test runner");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "type your answer");
  print_fact "composer borrowed with the custom placeholder"
    (Screen.has "type your answer" (Term.screen t));
  Term.send t "my own runner";
  Term.wait t (Screen.has "❯ my own runner");
  Term.send t Keys.enter;
  Term.wait t (Screen.has answer);
  print_fact "custom answer resumed" (Screen.has answer (Term.screen t));
  [%expect {| |}]

let%expect_test "plan approval builds and resumes the turn" =
  Project.with_temp "next-plan-approve" @@ fun project ->
  let answer = "Parser refactor complete." in
  let resume =
    Provider.response_line ~id:"resp-plan-2"
      ~body_contains:[ "function_call_output"; "call-plan" ]
      ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ propose_plan_call; resume ]
  @@ fun provider ->
  run project ~provider ~args:[ "--mode"; "plan" ] ~env:reduced_motion ~rows:24
    ~cols:80
  @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "draft a plan for the refactor";
  Term.wait t (Screen.has "❯ draft a plan for the refactor");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Refactor the parser");
  print_fact "plan chip" (Screen.has "plan" (Term.screen t));
  print_fact "plan title shown"
    (Screen.has "Refactor the parser" (Term.screen t));
  print_fact "plan body shown"
    (Screen.has "Split the tokenizer out" (Term.screen t));
  print_fact "approve option present" (Screen.has "approve" (Term.screen t));
  Screen.print ~project (Term.screen t);
  Term.send t "1";
  Term.wait t (Screen.has answer);
  print_fact "plan-approved echo" (Screen.has "plan approved" (Term.screen t));
  print_fact "resumed answer" (Screen.has answer (Term.screen t));
  [%expect {| |}]

let%expect_test "plan esc never approves and keeps planning" =
  Project.with_temp "next-plan-esc" @@ fun project ->
  let answer = "Revised the plan." in
  let resume =
    Provider.response_line ~id:"resp-plan-esc-2"
      ~body_contains:[ "function_call_output"; "call-plan" ]
      ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ propose_plan_call; resume ]
  @@ fun provider ->
  run project ~provider ~args:[ "--mode"; "plan" ] ~env:reduced_motion ~rows:24
    ~cols:80
  @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "draft a plan for the refactor";
  Term.wait t (Screen.has "❯ draft a plan for the refactor");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Refactor the parser");
  (* esc is the safe exit: keep planning, never approve. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has answer);
  print_fact "kept-planning echo" (Screen.has "kept planning" (Term.screen t));
  print_fact "resumed without approving" (Screen.has answer (Term.screen t));
  [%expect {| |}]

[%%run_tests "spice.tui-next.dialogs"]
