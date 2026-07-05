(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Tool_name_map = Map.Make (String)

type t = {
  usage : Spice_llm.Usage.t;
  responses : int;
  turns : int;
  tool_calls : int;
  tool_failures : int;
  tool_rejections : int;
  tool_calls_by_name : (string * int) list;
  permission_denials : int;
}

let invalid fn message = invalid_arg' "Spice_session.Metrics" fn message

let check_non_negative fn field value =
  if value < 0 then invalid fn (field ^ " must be non-negative")

let add_checked fn a b =
  if a > max_int - b then invalid fn "overflow" else a + b

let incr_checked fn value = add_checked fn value 1

let check_tool_calls_by_name fn entries =
  let rec loop previous = function
    | [] -> ()
    | (name, count) :: rest ->
        if String.is_empty name then
          invalid fn "tool call names must not be empty";
        if count <= 0 then
          invalid fn "tool call counts by name must be positive";
        begin match previous with
        | None -> ()
        | Some previous ->
            if String.compare previous name >= 0 then
              invalid fn "tool call counts by name must be sorted and unique"
        end;
        loop (Some name) rest
  in
  loop None entries

let make ~usage ~responses ~turns ~tool_calls ~tool_failures ~tool_rejections
    ~tool_calls_by_name ~permission_denials =
  check_non_negative "make" "responses" responses;
  check_non_negative "make" "turns" turns;
  check_non_negative "make" "tool_calls" tool_calls;
  check_non_negative "make" "tool_failures" tool_failures;
  check_non_negative "make" "tool_rejections" tool_rejections;
  check_non_negative "make" "permission_denials" permission_denials;
  if tool_failures > tool_calls then
    invalid "make" "tool_failures must not exceed tool_calls";
  check_tool_calls_by_name "make" tool_calls_by_name;
  {
    usage;
    responses;
    turns;
    tool_calls;
    tool_failures;
    tool_rejections;
    tool_calls_by_name;
    permission_denials;
  }

let empty =
  {
    usage = Spice_llm.Usage.zero;
    responses = 0;
    turns = 0;
    tool_calls = 0;
    tool_failures = 0;
    tool_rejections = 0;
    tool_calls_by_name = [];
    permission_denials = 0;
  }

type acc = {
  acc_usage : Spice_llm.Usage.t;
  acc_responses : int;
  acc_turns : int;
  acc_tool_calls : int;
  acc_tool_failures : int;
  acc_tool_rejections : int;
  acc_tool_calls_by_name : int Tool_name_map.t;
  acc_permission_denials : int;
}

let empty_acc : acc =
  {
    acc_usage = Spice_llm.Usage.zero;
    acc_responses = 0;
    acc_turns = 0;
    acc_tool_calls = 0;
    acc_tool_failures = 0;
    acc_tool_rejections = 0;
    acc_tool_calls_by_name = Tool_name_map.empty;
    acc_permission_denials = 0;
  }

let add_tool_call name counts =
  Tool_name_map.update name
    (function
      | None -> Some 1 | Some count -> Some (incr_checked "of_events" count))
    counts

let add_response response (acc : acc) =
  {
    acc with
    acc_usage =
      Spice_llm.Usage.add acc.acc_usage
        (Option.value
           (Spice_llm.Response.usage response)
           ~default:Spice_llm.Usage.zero);
    acc_responses = incr_checked "of_events" acc.acc_responses;
  }

let add_tool_finished execution (acc : acc) =
  let result = Tool_claim.Finished.result execution in
  {
    acc with
    acc_tool_calls = incr_checked "of_events" acc.acc_tool_calls;
    acc_tool_failures =
      (if Spice_llm.Tool.Result.is_error result then
         incr_checked "of_events" acc.acc_tool_failures
       else acc.acc_tool_failures);
    acc_tool_calls_by_name =
      add_tool_call
        (Spice_llm.Tool.Result.name result)
        acc.acc_tool_calls_by_name;
  }

let add_event acc = function
  | Event.Response_appended response -> add_response response acc
  | Event.Turn_finished _ ->
      { acc with acc_turns = incr_checked "of_events" acc.acc_turns }
  | Event.Tool_claim_finished execution -> add_tool_finished execution acc
  | Event.Message_appended (Spice_llm.Message.Tool_result result)
    when Spice_llm.Tool.Result.is_error result ->
      {
        acc with
        acc_tool_rejections = incr_checked "of_events" acc.acc_tool_rejections;
      }
  | Event.Permission_resolved reply -> (
      match Permission.Resolved.decision reply with
      | Permission.Resolved.Deny _ ->
          {
            acc with
            acc_permission_denials =
              incr_checked "of_events" acc.acc_permission_denials;
          }
      | Permission.Resolved.Allow _ -> acc)
  | Event.Turn_started _ | Event.Message_appended _
  | Event.Compaction_installed _ | Event.Permission_requested _
  | Event.Tool_claim_started _ ->
      acc

let of_events events =
  match events with
  | [] -> empty
  | _ :: _ ->
      let acc = List.fold_left add_event empty_acc events in
      let {
        acc_usage = usage;
        acc_responses = responses;
        acc_turns = turns;
        acc_tool_calls = tool_calls;
        acc_tool_failures = tool_failures;
        acc_tool_rejections = tool_rejections;
        acc_tool_calls_by_name = tool_calls_by_name;
        acc_permission_denials = permission_denials;
      } =
        acc
      in
      make ~usage ~responses ~turns ~tool_calls ~tool_failures ~tool_rejections
        ~tool_calls_by_name:(Tool_name_map.bindings tool_calls_by_name)
        ~permission_denials

let equal a b = a = b

let pp_by_name ppf entries =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
    (fun ppf (name, count) -> Format.fprintf ppf "%s=%d" name count)
    ppf entries

let pp ppf
    ({
       usage;
       responses;
       turns;
       tool_calls;
       tool_failures;
       tool_rejections;
       tool_calls_by_name;
       permission_denials;
     } :
      t) =
  Format.fprintf ppf
    "@[<hov>{ usage = %a; responses = %d; turns = %d; tool_calls = %d; \
     tool_failures = %d; tool_rejections = %d; tool_calls_by_name = [%a]; \
     permission_denials = %d }@]"
    Spice_llm.Usage.pp usage responses turns tool_calls tool_failures
    tool_rejections pp_by_name tool_calls_by_name permission_denials

let tool_call_count_jsont : (string * int) Jsont.t =
  Jsont.Object.map ~kind:"tool-call count" (fun name count -> (name, count))
  |> Jsont.Object.mem "name" Jsont.string ~enc:fst
  |> Jsont.Object.mem "count" Jsont.int ~enc:snd
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  let make usage responses turns tool_calls tool_failures tool_rejections
      (tool_calls_by_name : (string * int) list) permission_denials =
    decode_invalid_arg (fun () ->
        make ~usage ~responses ~turns ~tool_calls ~tool_failures
          ~tool_rejections ~tool_calls_by_name ~permission_denials)
  in
  Jsont.Object.map ~kind:"session metrics" make
  |> Jsont.Object.mem "usage" Spice_llm.Usage.jsont ~enc:(fun (t : t) ->
      t.usage)
  |> Jsont.Object.mem "responses" Jsont.int ~enc:(fun (t : t) -> t.responses)
  |> Jsont.Object.mem "turns" Jsont.int ~enc:(fun (t : t) -> t.turns)
  |> Jsont.Object.mem "tool_calls" Jsont.int ~enc:(fun (t : t) -> t.tool_calls)
  |> Jsont.Object.mem "tool_failures" Jsont.int ~enc:(fun (t : t) ->
      t.tool_failures)
  |> Jsont.Object.mem "tool_rejections" Jsont.int ~enc:(fun (t : t) ->
      t.tool_rejections)
  |> Jsont.Object.mem "tool_calls_by_name" (Jsont.list tool_call_count_jsont)
       ~enc:(fun (t : t) -> t.tool_calls_by_name)
  |> Jsont.Object.mem "permission_denials" Jsont.int ~enc:(fun (t : t) ->
      t.permission_denials)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
