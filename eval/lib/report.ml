(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type task_summary = {
  series : Result.series;
  runs : int;
  successes : int;
  mean_score : float;
  score_variance : float;
  mean_duration_s : float;
  mean_success_input_tokens : float option;
  mean_success_output_tokens : float option;
  mean_success_cost : float option;
  mean_cache_hit : float option;
}

type t = {
  tasks : task_summary list;
  success_costs : float list;
  failed_costs : float list;
  cached_tokens : int;
  uncached_tokens : int;
}

module Series_map = Map.Make (struct
  type t = Result.series

  let compare = compare
end)

let group_results results =
  let add result groups =
    Series_map.update (Result.series result)
      (function
        | None -> Some [ result ] | Some results -> Some (result :: results))
      groups
  in
  results
  |> List.fold_left (fun groups result -> add result groups) Series_map.empty
  |> Series_map.bindings

let mean values =
  match values with
  | [] -> 0.
  | _ :: _ ->
      List.fold_left ( +. ) 0. values /. float_of_int (List.length values)

let mean_opt values =
  match values with [] -> None | _ :: _ -> Some (mean values)

let variance values =
  match values with
  | [] -> 0.
  | _ :: _ ->
      let mu = mean values in
      mean (List.map (fun value -> (value -. mu) ** 2.) values)

let result_cache_hit result =
  match (Result.metrics_of result).Result.usage with
  | None -> None
  | Some usage ->
      let total = Usage.input_total usage in
      if total = 0 then None
      else Some (float_of_int usage.Usage.cache_read /. float_of_int total)

let result_cost cost result =
  match cost with None -> None | Some cost -> cost result

let successful result = (Result.score result).Result.success

let summarize_task cost (series, results) =
  let scores =
    List.map (fun result -> (Result.score result).Result.final) results
  in
  let successes = List.filter successful results in
  let success_usage =
    List.filter_map
      (fun result -> (Result.metrics_of result).Result.usage)
      successes
  in
  {
    series;
    runs = List.length results;
    successes = List.length successes;
    mean_score = mean scores;
    score_variance = variance scores;
    mean_duration_s =
      mean
        (List.map
           (fun result -> (Result.metrics_of result).Result.duration_s)
           results);
    mean_success_input_tokens =
      mean_opt
        (List.map
           (fun usage -> float_of_int (Usage.input_total usage))
           success_usage);
    mean_success_output_tokens =
      mean_opt
        (List.map
           (fun usage -> float_of_int (Usage.output_total usage))
           success_usage);
    mean_success_cost = mean_opt (List.filter_map (result_cost cost) successes);
    mean_cache_hit = mean_opt (List.filter_map result_cache_hit results);
  }

let of_results ?cost results =
  let tasks = group_results results |> List.map (summarize_task cost) in
  let priced_results which =
    results
    |> List.filter (fun result -> Bool.equal (successful result) which)
    |> List.filter_map (result_cost cost)
  in
  let usage_lane lane =
    List.fold_left
      (fun total result ->
        match (Result.metrics_of result).Result.usage with
        | None -> total
        | Some usage -> total + lane usage)
      0 results
  in
  {
    tasks;
    success_costs = priced_results true;
    failed_costs = priced_results false;
    cached_tokens = usage_lane (fun usage -> usage.Usage.cache_read);
    uncached_tokens =
      usage_lane (fun usage -> usage.Usage.input + usage.Usage.cache_write);
  }

let tasks t = t.tasks

let success_rate t =
  let runs = List.fold_left (fun total task -> total + task.runs) 0 t.tasks in
  if runs = 0 then 0.
  else
    let successes =
      List.fold_left (fun total task -> total + task.successes) 0 t.tasks
    in
    float_of_int successes /. float_of_int runs

let mean_score t = mean (List.map (fun task -> task.mean_score) t.tasks)
let cost_of_success t = mean_opt t.success_costs

let wasted_cost t =
  match t.failed_costs with
  | [] -> None
  | costs -> Some (List.fold_left ( +. ) 0. costs)

let cache_hit_rate t =
  let total = t.cached_tokens + t.uncached_tokens in
  if total = 0 then None
  else Some (float_of_int t.cached_tokens /. float_of_int total)

type metric = Success_rate | Mean_score | Cost_of_success | Cache_hit_rate
type verdict = Improved | Regressed | Unchanged

let verdict ~tolerance baseline current =
  if current > baseline +. tolerance then Improved
  else if current < baseline -. tolerance then Regressed
  else Unchanged

let cost_verdict ~tolerance baseline current =
  match verdict ~tolerance baseline current with
  | Improved -> Regressed
  | Regressed -> Improved
  | Unchanged -> Unchanged

let optional_metric metric verdict_of baseline current =
  match (baseline, current) with
  | Some baseline, Some current -> Some (metric, verdict_of baseline current)
  | Some _, None | None, Some _ | None, None -> None

let compare ?(success_tolerance = 0.) ?(score_tolerance = 0.05)
    ?(cost_tolerance = 0.10) ?(cache_hit_tolerance = 0.05) ~baseline t =
  [
    Some
      ( Success_rate,
        verdict ~tolerance:success_tolerance (success_rate baseline)
          (success_rate t) );
    Some
      ( Mean_score,
        verdict ~tolerance:score_tolerance (mean_score baseline) (mean_score t)
      );
    optional_metric Cost_of_success
      (fun baseline current ->
        cost_verdict ~tolerance:(baseline *. cost_tolerance) baseline current)
      (cost_of_success baseline) (cost_of_success t);
    optional_metric Cache_hit_rate
      (verdict ~tolerance:cache_hit_tolerance)
      (cache_hit_rate baseline) (cache_hit_rate t);
  ]
  |> List.filter_map Fun.id

let compare_tasks ?(score_tolerance = 0.05) ~baseline t =
  let baseline_scores =
    List.fold_left
      (fun map task -> Series_map.add task.series task.mean_score map)
      Series_map.empty baseline.tasks
  in
  List.filter_map
    (fun task ->
      match Series_map.find_opt task.series baseline_scores with
      | None -> None
      | Some baseline_score ->
          Some
            ( task.series,
              verdict ~tolerance:score_tolerance baseline_score task.mean_score
            ))
    t.tasks

let model_string series =
  Option.value series.Result.agent.Result.model ~default:"default"

let pp_task ppf (task : task_summary) =
  let series = task.series in
  Format.fprintf ppf "%s/%s/%s runs=%d successes=%d mean_score=%.3f"
    series.Result.agent.Result.name (model_string series) series.Result.task
    task.runs task.successes task.mean_score

let pp ppf t =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_cut ppf ())
    pp_task ppf t.tasks
