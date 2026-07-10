(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Usage = Spice_llm.Usage
module Model = Spice_llm.Model
module Provider = Spice_llm.Provider
module Reasoning_effort = Spice_llm.Request.Options.Reasoning_effort

type t = {
  responses : int;
  tool_calls : int;
  tool_failures : int;
  tool_rejections : int;
  input_tokens : int;
  output_tokens : int;
  reasoning_tokens : int;
  cache_read_tokens : int;
  cache_write_tokens : int;
  input_first : int option;
  input_last : int option;
  input_growth_mean : float option;
  cache_hit_rate : float option;
  calls_by_name : (string * int) list;
  result_bytes_total : int;
  result_bytes_by_name : (string * int) list;
  reread_count : int;
  repeated_call_count : int;
  failure_streak_max : int;
  segments : int;
  shell_families : (string * int) list;
  model : string option;
  reasoning_effort : string option;
}

let tally to_value calls =
  let table = Hashtbl.create 16 in
  List.iter
    (fun call ->
      let name = Trace.Call.name call in
      Hashtbl.replace table name
        (to_value call + Option.value (Hashtbl.find_opt table name) ~default:0))
    calls;
  Hashtbl.fold (fun name value acc -> (name, value) :: acc) table []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let rec pairwise = function
  | a :: (b :: _ as rest) -> (b - a) :: pairwise rest
  | [ _ ] | [] -> []

let of_trace trace =
  let steps = Trace.steps trace in
  let calls = Trace.calls trace in
  let usages = List.filter_map Trace.Step.usage steps in
  let sum lane = List.fold_left (fun acc usage -> acc + lane usage) 0 usages in
  let input_tokens = sum (fun u -> u.Usage.input) in
  let cache_read_tokens = sum (fun u -> u.Usage.cache_read) in
  let cache_write_tokens = sum (fun u -> u.Usage.cache_write) in
  let input_total_sum = input_tokens + cache_read_tokens + cache_write_tokens in
  let input_totals = List.map Usage.input_total usages in
  let deltas =
    List.concat_map
      (fun segment ->
        pairwise
          (List.filter_map
             (fun step -> Option.map Usage.input_total (Trace.Step.usage step))
             segment))
      (Trace.segments trace)
  in
  let count status =
    List.length
      (List.filter (fun call -> Trace.Call.status call = status) calls)
  in
  let executed =
    List.length
      (List.filter
         (fun call ->
           match Trace.Call.status call with
           | Trace.Call.Ok | Trace.Call.Failed -> true
           | Trace.Call.Rejected -> false)
         calls)
  in
  {
    responses = List.length steps;
    tool_calls = executed;
    tool_failures = count Trace.Call.Failed;
    tool_rejections = count Trace.Call.Rejected;
    input_tokens;
    output_tokens = sum (fun u -> u.Usage.output);
    reasoning_tokens = sum (fun u -> u.Usage.reasoning);
    cache_read_tokens;
    cache_write_tokens;
    input_first =
      (match input_totals with first :: _ -> Some first | [] -> None);
    input_last =
      (match List.rev input_totals with last :: _ -> Some last | [] -> None);
    input_growth_mean =
      (match deltas with
      | [] -> None
      | _ ->
          Some
            (float_of_int (List.fold_left ( + ) 0 deltas)
            /. float_of_int (List.length deltas)));
    cache_hit_rate =
      (if input_total_sum = 0 then None
       else Some (float_of_int cache_read_tokens /. float_of_int input_total_sum));
    calls_by_name = tally (fun _ -> 1) calls;
    result_bytes_total =
      List.fold_left
        (fun acc call -> acc + Trace.Call.result_bytes call)
        0 calls;
    result_bytes_by_name = tally Trace.Call.result_bytes calls;
    reread_count = List.length (Trace.rereads trace);
    repeated_call_count =
      List.fold_left
        (fun acc group -> acc + (List.length group - 1))
        0
        (Trace.repeated_groups trace);
    failure_streak_max =
      List.fold_left
        (fun acc streak -> max acc (List.length streak))
        0
        (Trace.failure_streaks trace);
    segments = List.length (Trace.segments trace);
    shell_families = Trace.shell_families trace;
    model =
      Option.map
        (fun m -> Provider.id (Model.provider m) ^ "/" ^ Model.id m)
        (Trace.model trace);
    reasoning_effort =
      Option.map Reasoning_effort.to_string (Trace.reasoning_effort trace);
  }

let entry_codec ~name_field ~value_field =
  Jsont.Object.map ~kind:"entry" (fun name value -> (name, value))
  |> Jsont.Object.mem name_field Jsont.string ~enc:fst
  |> Jsont.Object.mem value_field Jsont.int ~enc:snd
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let count_list =
  Jsont.list (entry_codec ~name_field:"name" ~value_field:"count")

let bytes_list =
  Jsont.list (entry_codec ~name_field:"name" ~value_field:"bytes")

let family_list =
  Jsont.list (entry_codec ~name_field:"family" ~value_field:"count")

let jsont =
  Jsont.Object.map ~kind:"trace_metrics"
    (fun
      responses
      tool_calls
      tool_failures
      tool_rejections
      input_tokens
      output_tokens
      reasoning_tokens
      cache_read_tokens
      cache_write_tokens
      input_first
      input_last
      input_growth_mean
      cache_hit_rate
      calls_by_name
      result_bytes_total
      result_bytes_by_name
      reread_count
      repeated_call_count
      failure_streak_max
      segments
      shell_families
      model
      reasoning_effort
    ->
      {
        responses;
        tool_calls;
        tool_failures;
        tool_rejections;
        input_tokens;
        output_tokens;
        reasoning_tokens;
        cache_read_tokens;
        cache_write_tokens;
        input_first;
        input_last;
        input_growth_mean;
        cache_hit_rate;
        calls_by_name;
        result_bytes_total;
        result_bytes_by_name;
        reread_count;
        repeated_call_count;
        failure_streak_max;
        segments;
        shell_families;
        model;
        reasoning_effort;
      })
  |> Jsont.Object.mem "responses" Jsont.int ~enc:(fun t -> t.responses)
  |> Jsont.Object.mem "tool_calls" Jsont.int ~enc:(fun t -> t.tool_calls)
  |> Jsont.Object.mem "tool_failures" Jsont.int ~enc:(fun t -> t.tool_failures)
  |> Jsont.Object.mem "tool_rejections" Jsont.int ~enc:(fun t ->
      t.tool_rejections)
  |> Jsont.Object.mem "input_tokens" Jsont.int ~enc:(fun t -> t.input_tokens)
  |> Jsont.Object.mem "output_tokens" Jsont.int ~enc:(fun t -> t.output_tokens)
  |> Jsont.Object.mem "reasoning_tokens" Jsont.int ~enc:(fun t ->
      t.reasoning_tokens)
  |> Jsont.Object.mem "cache_read_tokens" Jsont.int ~enc:(fun t ->
      t.cache_read_tokens)
  |> Jsont.Object.mem "cache_write_tokens" Jsont.int ~enc:(fun t ->
      t.cache_write_tokens)
  |> Jsont.Object.opt_mem "input_first" Jsont.int ~enc:(fun t -> t.input_first)
  |> Jsont.Object.opt_mem "input_last" Jsont.int ~enc:(fun t -> t.input_last)
  |> Jsont.Object.opt_mem "input_growth_mean" Jsont.number ~enc:(fun t ->
      t.input_growth_mean)
  |> Jsont.Object.opt_mem "cache_hit_rate" Jsont.number ~enc:(fun t ->
      t.cache_hit_rate)
  |> Jsont.Object.mem "calls_by_name" count_list ~enc:(fun t -> t.calls_by_name)
  |> Jsont.Object.mem "result_bytes_total" Jsont.int ~enc:(fun t ->
      t.result_bytes_total)
  |> Jsont.Object.mem "result_bytes_by_name" bytes_list ~enc:(fun t ->
      t.result_bytes_by_name)
  |> Jsont.Object.mem "reread_count" Jsont.int ~enc:(fun t -> t.reread_count)
  |> Jsont.Object.mem "repeated_call_count" Jsont.int ~enc:(fun t ->
      t.repeated_call_count)
  |> Jsont.Object.mem "failure_streak_max" Jsont.int ~enc:(fun t ->
      t.failure_streak_max)
  |> Jsont.Object.mem "segments" Jsont.int ~enc:(fun t -> t.segments)
  |> Jsont.Object.mem "shell_families" family_list ~enc:(fun t ->
      t.shell_families)
  |> Jsont.Object.opt_mem "model" Jsont.string ~enc:(fun t -> t.model)
  |> Jsont.Object.opt_mem "reasoning_effort" Jsont.string ~enc:(fun t ->
      t.reasoning_effort)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
