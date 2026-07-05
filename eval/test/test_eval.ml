(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Eval = Spice_eval

let check_value = testable ~pp:Eval.Check.pp ~equal:Eval.Check.equal ()
let float_value = testable ~pp:Format.pp_print_float ~equal:Float.equal ()

let expect_invalid_arg msg f =
  match f () with
  | _ -> failf "%s: expected Invalid_argument" msg
  | exception Invalid_argument _ -> ()

let pp_metric ppf = function
  | Eval.Report.Success_rate -> Format.pp_print_string ppf "success-rate"
  | Eval.Report.Mean_score -> Format.pp_print_string ppf "mean-score"
  | Eval.Report.Cost_of_success -> Format.pp_print_string ppf "cost-of-success"
  | Eval.Report.Cache_hit_rate -> Format.pp_print_string ppf "cache-hit-rate"

let pp_verdict ppf = function
  | Eval.Report.Improved -> Format.pp_print_string ppf "improved"
  | Eval.Report.Regressed -> Format.pp_print_string ppf "regressed"
  | Eval.Report.Unchanged -> Format.pp_print_string ppf "unchanged"

let metric_value = testable ~pp:pp_metric ~equal:( = ) ()
let verdict_value = testable ~pp:pp_verdict ~equal:( = ) ()

let encode codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failf "encode failed: %s" message

let decode codec json =
  match Jsont.Json.decode codec json with
  | Ok value -> value
  | Error message -> failf "decode failed: %s" message

let metrics ?usage () = Eval.Result.metrics ~duration_s:0. ?usage ()

let series ?(task = "task") ?(agent = "spice") ?(model = Some "test") () =
  {
    Eval.Result.task;
    agent =
      {
        Eval.Result.name = agent;
        Eval.Result.version = Some "test-agent";
        Eval.Result.model;
      };
    judge_model = None;
    spice_version = Some "test-spice";
  }

let make_result ?(task = "task") ?(agent = "spice") ?(model = Some "test")
    ?(run_index = 0) ?(status = Eval.Result.Completed) ?usage findings =
  Eval.Result.make
    ~series:(series ~task ~agent ~model ())
    ~run_index ~status ~metrics:(metrics ?usage ()) ~findings ()

let check_constructors_validate_invariants () =
  let build =
    Eval.Check.gate "build" (Eval.Check.shell "dune build --root .")
  in
  equal check_value ~msg:"gate" build
    (Eval.Check.gate "build" (Eval.Check.shell "dune build --root ."));
  expect_invalid_arg "empty command" (fun () -> Eval.Check.shell "");
  expect_invalid_arg "empty diff scope" (fun () -> Eval.Check.diff_within []);
  expect_invalid_arg "empty judge criterion" (fun () ->
      Eval.Check.judge "quality" ~criterion:"" ());
  expect_invalid_arg "nan penalty" (fun () ->
      Eval.Check.penalty "penalty" ~points:nan (Eval.Check.shell "true"));
  ignore (Eval.Check.diff_touches_any [ "test/**" ]);
  ignore (Eval.Check.diff_touches_all [ "lib/**"; "test/**" ])

let task_constructor_validates_invariants () =
  let check = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let task =
    Eval.Task.make ~setup:[ "dune build" ]
      ~limits:{ Eval.Task.timeout_s = Some 30.; Eval.Task.steps = Some 3 }
      ~tags:[ "bugfix" ]
      ~metadata:[ ("size", "S") ]
      "task" ~source:(Eval.Task.dir ".") ~prompt:"Fix the bug" [ check ]
  in
  equal string ~msg:"task id" "task" (Eval.Task.id task);
  equal (list check_value) ~msg:"checks" [ check ] (Eval.Task.checks task);
  equal (list string) ~msg:"tags" [ "bugfix" ] (Eval.Task.tags task);
  expect_invalid_arg "empty checks" (fun () ->
      Eval.Task.make "task" ~source:(Eval.Task.dir ".") ~prompt:"Fix the bug" []);
  expect_invalid_arg "duplicate checks" (fun () ->
      Eval.Task.make "task" ~source:(Eval.Task.dir ".") ~prompt:"Fix the bug"
        [ check; check ]);
  expect_invalid_arg "empty metadata key" (fun () ->
      Eval.Task.make
        ~metadata:[ ("", "S") ]
        "task" ~source:(Eval.Task.dir ".") ~prompt:"Fix the bug" [ check ])

let metrics_validate_invariants () =
  ignore (Eval.Result.metrics ~duration_s:0. ());
  expect_invalid_arg "tool failures exceed calls" (fun () ->
      Eval.Result.metrics ~duration_s:0. ~tool_calls:1 ~tool_failures:2 ());
  expect_invalid_arg "nan duration" (fun () ->
      Eval.Result.metrics ~duration_s:nan ())

let scoring_combines_gates_quality_and_penalties () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let quality = Eval.Check.judge "correctness" ~criterion:"Correct fix" () in
  let penalty =
    Eval.Check.penalty "scope" ~points:0.25
      (Eval.Check.diff_within [ "lib/**" ])
  in
  let result =
    make_result
      [
        Eval.Result.passed gate;
        Eval.Result.scored quality ~score:0.75 ~samples:[];
        Eval.Result.failed penalty "touched unrelated file";
      ]
    |> Eval.Result.score
  in
  is_true ~msg:"successful result" result.Eval.Result.success;
  equal (option float_value) ~msg:"quality" (Some 0.75)
    result.Eval.Result.quality;
  equal float_value ~msg:"penalties" 0.25 result.Eval.Result.penalties;
  equal float_value ~msg:"final" 0.5 result.Eval.Result.final

let failed_gate_or_incomplete_status_zeroes_final_score () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let quality = Eval.Check.judge "correctness" ~criterion:"Correct fix" () in
  let failed_gate =
    make_result
      [ Eval.Result.failed gate "build failed"; Eval.Result.skipped quality ]
    |> Eval.Result.score
  in
  let blocked =
    make_result ~status:Eval.Result.Blocked
      [
        Eval.Result.passed gate;
        Eval.Result.scored quality ~score:1. ~samples:[];
      ]
    |> Eval.Result.score
  in
  is_true ~msg:"failed gate is unsuccessful"
    (not failed_gate.Eval.Result.success);
  equal float_value ~msg:"failed gate final" 0. failed_gate.Eval.Result.final;
  is_true ~msg:"blocked result is unsuccessful"
    (not blocked.Eval.Result.success);
  equal float_value ~msg:"blocked final" 0. blocked.Eval.Result.final

let skipped_quality_is_visible_but_gate_only_scores_one () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let quality = Eval.Check.judge "correctness" ~criterion:"Correct fix" () in
  let unjudged =
    make_result [ Eval.Result.passed gate; Eval.Result.skipped quality ]
    |> Eval.Result.score
  in
  let gate_only =
    make_result [ Eval.Result.passed gate ] |> Eval.Result.score
  in
  is_true ~msg:"unjudged result is successful" unjudged.Eval.Result.success;
  is_true ~msg:"missing quality visible" unjudged.Eval.Result.missing_quality;
  equal (option float_value) ~msg:"unjudged quality" None
    unjudged.Eval.Result.quality;
  equal float_value ~msg:"unjudged final" 1. unjudged.Eval.Result.final;
  is_true ~msg:"gate-only has no missing quality"
    (not gate_only.Eval.Result.missing_quality);
  equal float_value ~msg:"gate-only final" 1. gate_only.Eval.Result.final;
  expect_invalid_arg "judge findings cannot pass" (fun () ->
      Eval.Result.passed quality);
  expect_invalid_arg "gate findings cannot be scored" (fun () ->
      Eval.Result.scored gate ~score:1. ~samples:[])

let report_groups_by_full_series () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let passed = [ Eval.Result.passed gate ] in
  let a = make_result ~task:"a" passed in
  let b = make_result ~task:"a" ~model:(Some "other") passed in
  let report = Eval.Report.of_results [ a; b ] in
  let tasks = Eval.Report.tasks report in
  equal int ~msg:"series count" 2 (List.length tasks);
  equal (list string) ~msg:"models" [ "other"; "test" ]
    (List.map
       (fun task ->
         Option.get task.Eval.Report.series.Eval.Result.agent.Eval.Result.model)
       tasks)

let report_aggregates_usage_and_cost () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let usage = Eval.Usage.make ~input:1000 ~output:100 ~cache_read:500 () in
  let results =
    [
      make_result ~usage [ Eval.Result.passed gate ];
      make_result ~run_index:1 ~usage [ Eval.Result.failed gate "build failed" ];
    ]
  in
  let cost result =
    equal (option string) ~msg:"cost model" (Some "test")
      (Eval.Result.series result).Eval.Result.agent.Eval.Result.model;
    Option.map
      (fun usage ->
        float_of_int
          (Eval.Usage.input_total usage + Eval.Usage.output_total usage)
        /. 1000.)
      (Eval.Result.metrics_of result).Eval.Result.usage
  in
  let report = Eval.Report.of_results ~cost results in
  let task = List.hd (Eval.Report.tasks report) in
  equal float_value ~msg:"mean success input tokens" 1500.
    (Option.get task.Eval.Report.mean_success_input_tokens);
  equal float_value ~msg:"mean success output tokens" 100.
    (Option.get task.Eval.Report.mean_success_output_tokens);
  equal float_value ~msg:"mean success cost" 1.6
    (Option.get task.Eval.Report.mean_success_cost);
  equal float_value ~msg:"cost of success" 1.6
    (Option.get (Eval.Report.cost_of_success report));
  equal float_value ~msg:"wasted cost" 1.6
    (Option.get (Eval.Report.wasted_cost report));
  equal float_value ~msg:"score variance" 0.25 task.Eval.Report.score_variance;
  equal float_value ~msg:"mean cache hit" (500. /. 1500.)
    (Option.get task.Eval.Report.mean_cache_hit);
  equal float_value ~msg:"report cache hit rate" (1000. /. 3000.)
    (Option.get (Eval.Report.cache_hit_rate report));
  let unpriced = Eval.Report.of_results results in
  is_true ~msg:"no cost function means no cost"
    (Option.is_none (Eval.Report.cost_of_success unpriced))

let compare_reports () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let passed = [ Eval.Result.passed gate ] in
  let failed = [ Eval.Result.failed gate "build failed" ] in
  let baseline =
    Eval.Report.of_results
      [ make_result ~task:"a" failed; make_result ~task:"b" passed ]
  in
  let current =
    Eval.Report.of_results
      [
        make_result ~task:"a" passed;
        make_result ~task:"b" failed;
        make_result ~task:"new" passed;
      ]
  in
  equal
    (list (pair metric_value verdict_value))
    ~msg:"headline comparison"
    [
      (Eval.Report.Success_rate, Eval.Report.Improved);
      (Eval.Report.Mean_score, Eval.Report.Improved);
    ]
    (Eval.Report.compare ~baseline current);
  equal (list verdict_value) ~msg:"per-series verdicts"
    [ Eval.Report.Improved; Eval.Report.Regressed ]
    (Eval.Report.compare_tasks ~baseline current |> List.map snd)

let result_codec_round_trips () =
  let gate = Eval.Check.gate "build" (Eval.Check.shell "dune build") in
  let quality = Eval.Check.judge "correctness" ~criterion:"Correct fix" () in
  let result =
    make_result
      [
        Eval.Result.passed gate;
        Eval.Result.scored quality ~score:0.75
          ~samples:
            [
              {
                Eval.Result.sample_score = 0.75;
                Eval.Result.rationale = "mostly correct";
              };
            ];
      ]
  in
  equal
    (testable ~pp:Eval.Result.pp ~equal:Eval.Result.equal ())
    ~msg:"result codec" result
    (decode Eval.Result.jsont (encode Eval.Result.jsont result))

let () =
  Windtrap.run "spice.eval"
    [
      test "check constructors validate invariants"
        check_constructors_validate_invariants;
      test "task constructor validates invariants"
        task_constructor_validates_invariants;
      test "metrics validate invariants" metrics_validate_invariants;
      test "scoring combines gates quality and penalties"
        scoring_combines_gates_quality_and_penalties;
      test "failed gate or incomplete status zeroes final score"
        failed_gate_or_incomplete_status_zeroes_final_score;
      test "skipped quality is visible but gate-only scores one"
        skipped_quality_is_visible_but_gate_only_scores_one;
      test "report groups by full series" report_groups_by_full_series;
      test "report aggregates usage and cost" report_aggregates_usage_and_cost;
      test "compare reports" compare_reports;
      test "result codec round trips" result_codec_round_trips;
    ]
