(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type failure_stage =
  | Setup
  | Agent
  | Check of string
  | Judge of string
  | Harness

type failure = {
  stage : failure_stage;
  message : string;
  failure_log : string option;
}

type agent_status = Completed | Blocked | Timed_out | Failed of failure
type agent = { name : string; version : string option; model : string option }

type series = {
  task : string;
  agent : agent;
  judge_model : string option;
  spice_version : string option;
}

type metrics = {
  duration_s : float;
  usage : Usage.t option;
  turns : int option;
  tool_calls : int option;
  tool_failures : int option;
  tool_rejections : int option;
  log : string option;
}

type sample = { sample_score : float; rationale : string }

type verdict =
  | Passed
  | Failed_check of string
  | Scored of { score : float; samples : sample list }
  | Skipped

type finding = { check : Check.t; verdict : verdict }

type score = {
  success : bool;
  quality : float option;
  penalties : float;
  final : float;
  missing_quality : bool;
}

type t = {
  series : series;
  run_index : int;
  status : agent_status;
  metrics : metrics;
  findings : finding list;
  score : score;
}

let invalid fn message = invalid_arg ("Spice_eval.Result." ^ fn ^ ": " ^ message)
let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message -> decode_error message

let non_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let non_empty_option fn field = function
  | None -> ()
  | Some value -> non_empty fn field value

let non_negative_int fn field = function
  | None -> ()
  | Some value when value >= 0 -> ()
  | Some _ -> invalid fn (field ^ " must be non-negative")

let non_negative_float fn field value =
  match classify_float value with
  | FP_zero -> ()
  | FP_normal | FP_subnormal ->
      if value < 0. then invalid fn (field ^ " must be non-negative")
  | FP_infinite | FP_nan -> invalid fn (field ^ " must be non-negative")

let score_in_unit_interval fn field value =
  match classify_float value with
  | FP_zero -> ()
  | (FP_normal | FP_subnormal) when value >= 0. && value <= 1. -> ()
  | FP_normal | FP_subnormal | FP_infinite | FP_nan ->
      invalid fn (field ^ " must be between 0 and 1")

let metrics ~duration_s ?usage ?turns ?tool_calls ?tool_failures
    ?tool_rejections ?log () =
  non_negative_float "metrics" "duration_s" duration_s;
  non_negative_int "metrics" "turns" turns;
  non_negative_int "metrics" "tool_calls" tool_calls;
  non_negative_int "metrics" "tool_failures" tool_failures;
  non_negative_int "metrics" "tool_rejections" tool_rejections;
  (match (tool_calls, tool_failures) with
  | Some tool_calls, Some tool_failures when tool_failures > tool_calls ->
      invalid "metrics" "tool_failures must not exceed tool_calls"
  | Some _, Some _ | Some _, None | None, Some _ | None, None -> ());
  non_empty_option "metrics" "log" log;
  { duration_s; usage; turns; tool_calls; tool_failures; tool_rejections; log }

let validate_failure fn (failure : failure) =
  non_empty fn "failure message" failure.message;
  non_empty_option fn "failure log" failure.failure_log;
  match failure.stage with
  | Check name | Judge name -> non_empty fn "failure stage check" name
  | Setup | Agent | Harness -> ()

let validate_status fn = function
  | Completed | Blocked | Timed_out -> ()
  | Failed failure -> validate_failure fn failure

let validate_sample fn (sample : sample) =
  score_in_unit_interval fn "sample score" sample.sample_score;
  non_empty fn "sample rationale" sample.rationale

let finding check verdict =
  (match verdict with
  | Passed | Skipped -> ()
  | Failed_check message -> non_empty "finding" "failure message" message
  | Scored { score; samples } ->
      score_in_unit_interval "finding" "score" score;
      List.iter (validate_sample "finding") samples);
  (match (Check.kind check, verdict) with
  | (`Gate | `Penalty _), (Passed | Failed_check _ | Skipped) -> ()
  | `Judge _, (Scored _ | Skipped) -> ()
  | (`Gate | `Penalty _), Scored _ ->
      invalid "finding" "scored verdicts require a judge check"
  | `Judge _, (Passed | Failed_check _) ->
      invalid "finding" "judge findings must be scored or skipped");
  { check; verdict }

let passed check = finding check Passed
let failed check message = finding check (Failed_check message)
let scored check ~score ~samples = finding check (Scored { score; samples })
let skipped check = finding check Skipped
let finding_check t = t.check
let finding_verdict t = t.verdict

let completed = function
  | Completed -> true
  | Blocked | Timed_out | Failed _ -> false

let gate_failed finding =
  match (Check.kind finding.check, finding.verdict) with
  | `Gate, Failed_check _ -> true
  | ( (`Gate | `Penalty _ | `Judge _),
      (Passed | Failed_check _ | Scored _ | Skipped) ) ->
      false

let penalty_points finding =
  match (Check.kind finding.check, finding.verdict) with
  | `Penalty points, Failed_check _ -> points
  | ( (`Penalty _ | `Gate | `Judge _),
      (Passed | Failed_check _ | Scored _ | Skipped) ) ->
      0.

let quality_score finding =
  match (Check.kind finding.check, finding.verdict) with
  | `Judge weight, Scored { score; _ } -> Some (weight, score)
  | ( (`Judge _ | `Gate | `Penalty _),
      (Passed | Failed_check _ | Scored _ | Skipped) ) ->
      None

let has_judge finding =
  match Check.kind finding.check with
  | `Judge _ -> true
  | `Gate | `Penalty _ -> false

let weighted_mean weighted =
  match weighted with
  | [] -> None
  | _ :: _ ->
      let total_weight, weighted_score =
        List.fold_left
          (fun (total_weight, weighted_score) (weight, score) ->
            (total_weight +. weight, weighted_score +. (weight *. score)))
          (0., 0.) weighted
      in
      if total_weight = 0. then None else Some (weighted_score /. total_weight)

let score_of_findings ~status findings =
  let success = completed status && not (List.exists gate_failed findings) in
  let quality = weighted_mean (List.filter_map quality_score findings) in
  let penalties =
    List.fold_left
      (fun total finding -> total +. penalty_points finding)
      0. findings
  in
  let missing_quality =
    List.exists has_judge findings && Option.is_none quality
  in
  let base = Option.value quality ~default:1. in
  let final = if success then max 0. (base -. penalties) else 0. in
  { success; quality; penalties; final; missing_quality }

let check_unique_findings findings =
  let rec loop seen = function
    | [] -> ()
    | finding :: rest ->
        let name = Check.name finding.check in
        if List.exists (String.equal name) seen then
          invalid "make" ("duplicate finding name: " ^ name);
        loop (name :: seen) rest
  in
  loop [] findings

let validate_series series =
  non_empty "make" "task" series.task;
  non_empty "make" "agent name" series.agent.name;
  non_empty_option "make" "agent version" series.agent.version;
  non_empty_option "make" "agent model" series.agent.model;
  non_empty_option "make" "judge_model" series.judge_model;
  non_empty_option "make" "spice_version" series.spice_version

let make ~series ~run_index ~status ~metrics ~findings () =
  validate_series series;
  if run_index < 0 then invalid "make" "run_index must be non-negative";
  validate_status "make" status;
  check_unique_findings findings;
  let score = score_of_findings ~status findings in
  { series; run_index; status; metrics; findings; score }

let series t = t.series
let run_index t = t.run_index
let status t = t.status
let metrics_of t = t.metrics
let findings t = t.findings
let score (t : t) = t.score

let pp_failure_stage ppf = function
  | Setup -> Format.pp_print_string ppf "setup"
  | Agent -> Format.pp_print_string ppf "agent"
  | Check name -> Format.fprintf ppf "check(%s)" name
  | Judge name -> Format.fprintf ppf "judge(%s)" name
  | Harness -> Format.pp_print_string ppf "harness"

let pp_status ppf = function
  | Completed -> Format.pp_print_string ppf "completed"
  | Blocked -> Format.pp_print_string ppf "blocked"
  | Timed_out -> Format.pp_print_string ppf "timed-out"
  | Failed failure ->
      Format.fprintf ppf "failed(%a: %s)" pp_failure_stage failure.stage
        failure.message

let pp_verdict ppf = function
  | Passed -> Format.pp_print_string ppf "passed"
  | Failed_check message -> Format.fprintf ppf "failed(%s)" message
  | Scored { score; _ } -> Format.fprintf ppf "scored(%.3f)" score
  | Skipped -> Format.pp_print_string ppf "skipped"

let pp_finding ppf t =
  Format.fprintf ppf "%s: %a" (Check.name t.check) pp_verdict t.verdict

let pp_score ppf t =
  Format.fprintf ppf
    "{ success = %b; quality = %s; penalties = %.3f; final = %.3f; \
     missing_quality = %b }"
    t.success
    (match t.quality with None -> "none" | Some v -> Printf.sprintf "%.3f" v)
    t.penalties t.final t.missing_quality

let pp ppf t =
  let model = Option.value t.series.agent.model ~default:"default" in
  Format.fprintf ppf "%s/%s/%s#%d %a" t.series.agent.name model t.series.task
    t.run_index pp_score t.score

let equal a b = a = b
let artifact_version = 2

let failure_stage_jsont =
  let setup_case =
    Jsont.Object.map ~kind:"setup failure stage" Setup
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "setup" ~dec:Fun.id
  in
  let agent_case =
    Jsont.Object.map ~kind:"agent failure stage" Agent
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "agent" ~dec:Fun.id
  in
  let check_case =
    Jsont.Object.map ~kind:"check failure stage" (fun name ->
        decode_invalid_arg (fun () ->
            non_empty "jsont" "failure stage check" name;
            Check name))
    |> Jsont.Object.mem "name" Jsont.string ~enc:(function
      | Check name -> name
      | Setup | Agent | Judge _ | Harness -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "check" ~dec:Fun.id
  in
  let judge_case =
    Jsont.Object.map ~kind:"judge failure stage" (fun name ->
        decode_invalid_arg (fun () ->
            non_empty "jsont" "failure stage check" name;
            Judge name))
    |> Jsont.Object.mem "name" Jsont.string ~enc:(function
      | Judge name -> name
      | Setup | Agent | Check _ | Harness -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "judge" ~dec:Fun.id
  in
  let harness_case =
    Jsont.Object.map ~kind:"harness failure stage" Harness
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "harness" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [ setup_case; agent_case; check_case; judge_case; harness_case ]
  in
  let enc_case = function
    | Setup as stage -> Jsont.Object.Case.value setup_case stage
    | Agent as stage -> Jsont.Object.Case.value agent_case stage
    | Check _ as stage -> Jsont.Object.Case.value check_case stage
    | Judge _ as stage -> Jsont.Object.Case.value judge_case stage
    | Harness as stage -> Jsont.Object.Case.value harness_case stage
  in
  Jsont.Object.map ~kind:"eval failure stage" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let failure_jsont =
  let make stage message log =
    decode_invalid_arg (fun () ->
        let failure : failure = { stage; message; failure_log = log } in
        validate_failure "jsont" failure;
        failure)
  in
  Jsont.Object.map ~kind:"eval failure" make
  |> Jsont.Object.mem "stage" failure_stage_jsont ~enc:(fun (t : failure) ->
      t.stage)
  |> Jsont.Object.mem "message" Jsont.string ~enc:(fun (t : failure) ->
      t.message)
  |> Jsont.Object.opt_mem "log" Jsont.string ~enc:(fun (t : failure) ->
      t.failure_log)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let status_jsont =
  let completed_case =
    Jsont.Object.map ~kind:"completed eval status" Completed
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "completed" ~dec:Fun.id
  in
  let blocked_case =
    Jsont.Object.map ~kind:"blocked eval status" Blocked
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "blocked" ~dec:Fun.id
  in
  let timed_out_case =
    Jsont.Object.map ~kind:"timed-out eval status" Timed_out
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "timed_out" ~dec:Fun.id
  in
  let failed_case =
    Jsont.Object.map ~kind:"failed eval status" (fun failure -> Failed failure)
    |> Jsont.Object.mem "failure" failure_jsont ~enc:(function
      | Failed failure -> failure
      | Completed | Blocked | Timed_out -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "failed" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [ completed_case; blocked_case; timed_out_case; failed_case ]
  in
  let enc_case = function
    | Completed as status -> Jsont.Object.Case.value completed_case status
    | Blocked as status -> Jsont.Object.Case.value blocked_case status
    | Timed_out as status -> Jsont.Object.Case.value timed_out_case status
    | Failed _ as status -> Jsont.Object.Case.value failed_case status
  in
  Jsont.Object.map ~kind:"eval status" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let agent_jsont =
  let make name version model =
    decode_invalid_arg (fun () ->
        non_empty "jsont" "agent name" name;
        non_empty_option "jsont" "agent version" version;
        non_empty_option "jsont" "agent model" model;
        { name; version; model })
  in
  Jsont.Object.map ~kind:"eval agent identity" make
  |> Jsont.Object.mem "name" Jsont.string ~enc:(fun (t : agent) -> t.name)
  |> Jsont.Object.opt_mem "version" Jsont.string ~enc:(fun (t : agent) ->
      t.version)
  |> Jsont.Object.opt_mem "model" Jsont.string ~enc:(fun (t : agent) -> t.model)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let series_jsont =
  let make task agent judge_model spice_version =
    decode_invalid_arg (fun () ->
        let series = { task; agent; judge_model; spice_version } in
        validate_series series;
        series)
  in
  Jsont.Object.map ~kind:"eval result series" make
  |> Jsont.Object.mem "task" Jsont.string ~enc:(fun (t : series) -> t.task)
  |> Jsont.Object.mem "agent" agent_jsont ~enc:(fun (t : series) -> t.agent)
  |> Jsont.Object.opt_mem "judge_model" Jsont.string ~enc:(fun (t : series) ->
      t.judge_model)
  |> Jsont.Object.opt_mem "spice_version" Jsont.string ~enc:(fun (t : series) ->
      t.spice_version)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let metrics_jsont =
  let make duration_s usage turns tool_calls tool_failures tool_rejections log =
    decode_invalid_arg (fun () ->
        metrics ~duration_s ?usage ?turns ?tool_calls ?tool_failures
          ?tool_rejections ?log ())
  in
  Jsont.Object.map ~kind:"eval metrics" make
  |> Jsont.Object.mem "duration_s" Jsont.number ~enc:(fun (t : metrics) ->
      t.duration_s)
  |> Jsont.Object.opt_mem "usage" Usage.jsont ~enc:(fun (t : metrics) ->
      t.usage)
  |> Jsont.Object.opt_mem "turns" Jsont.int ~enc:(fun (t : metrics) -> t.turns)
  |> Jsont.Object.opt_mem "tool_calls" Jsont.int ~enc:(fun (t : metrics) ->
      t.tool_calls)
  |> Jsont.Object.opt_mem "tool_failures" Jsont.int ~enc:(fun (t : metrics) ->
      t.tool_failures)
  |> Jsont.Object.opt_mem "tool_rejections" Jsont.int ~enc:(fun (t : metrics) ->
      t.tool_rejections)
  |> Jsont.Object.opt_mem "log" Jsont.string ~enc:(fun (t : metrics) -> t.log)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let sample_jsont =
  let make score rationale =
    decode_invalid_arg (fun () ->
        let sample : sample = { sample_score = score; rationale } in
        validate_sample "jsont" sample;
        sample)
  in
  Jsont.Object.map ~kind:"eval score sample" make
  |> Jsont.Object.mem "score" Jsont.number ~enc:(fun (t : sample) ->
      t.sample_score)
  |> Jsont.Object.mem "rationale" Jsont.string ~enc:(fun (t : sample) ->
      t.rationale)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let verdict_jsont =
  let passed_case =
    Jsont.Object.map ~kind:"passed eval finding verdict" Passed
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "passed" ~dec:Fun.id
  in
  let failed_case =
    Jsont.Object.map ~kind:"failed eval finding verdict" (fun message ->
        decode_invalid_arg (fun () ->
            non_empty "jsont" "failure message" message;
            Failed_check message))
    |> Jsont.Object.mem "message" Jsont.string ~enc:(function
      | Failed_check message -> message
      | Passed | Scored _ | Skipped -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "failed" ~dec:Fun.id
  in
  let scored_case =
    Jsont.Object.map ~kind:"scored eval finding verdict" (fun score samples ->
        decode_invalid_arg (fun () ->
            score_in_unit_interval "jsont" "score" score;
            List.iter (validate_sample "jsont") samples;
            Scored { score; samples }))
    |> Jsont.Object.mem "score" Jsont.number ~enc:(function
      | Scored { score; _ } -> score
      | Passed | Failed_check _ | Skipped -> assert false)
    |> Jsont.Object.mem "samples" (Jsont.list sample_jsont) ~enc:(function
      | Scored { samples; _ } -> samples
      | Passed | Failed_check _ | Skipped -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "scored" ~dec:Fun.id
  in
  let skipped_case =
    Jsont.Object.map ~kind:"skipped eval finding verdict" Skipped
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "skipped" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [ passed_case; failed_case; scored_case; skipped_case ]
  in
  let enc_case = function
    | Passed as verdict -> Jsont.Object.Case.value passed_case verdict
    | Failed_check _ as verdict -> Jsont.Object.Case.value failed_case verdict
    | Scored _ as verdict -> Jsont.Object.Case.value scored_case verdict
    | Skipped as verdict -> Jsont.Object.Case.value skipped_case verdict
  in
  Jsont.Object.map ~kind:"eval finding verdict" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let finding_jsont =
  let make check verdict =
    decode_invalid_arg (fun () -> finding check verdict)
  in
  Jsont.Object.map ~kind:"eval finding" make
  |> Jsont.Object.mem "check" Check.jsont ~enc:finding_check
  |> Jsont.Object.mem "verdict" verdict_jsont ~enc:finding_verdict
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  let make version series run_index status metrics findings =
    decode_invalid_arg (fun () ->
        if version <> artifact_version then
          invalid "jsont"
            ("unsupported result version: " ^ string_of_int version);
        make ~series ~run_index ~status ~metrics ~findings ())
  in
  Jsont.Object.map ~kind:"eval result" make
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> artifact_version)
  |> Jsont.Object.mem "series" series_jsont ~enc:series
  |> Jsont.Object.mem "run_index" Jsont.int ~enc:run_index
  |> Jsont.Object.mem "status" status_jsont ~enc:status
  |> Jsont.Object.mem "metrics" metrics_jsont ~enc:metrics_of
  |> Jsont.Object.mem "findings" (Jsont.list finding_jsont) ~enc:findings
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
