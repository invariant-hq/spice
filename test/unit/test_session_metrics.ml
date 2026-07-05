(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Json = Jsont.Json
module Llm = Spice_llm
module Session = Spice_session
module Metrics = Session.Metrics

let metrics_value = testable ~pp:Metrics.pp ~equal:Metrics.equal ()
let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5"
let cwd = Spice_path.Abs.of_string_exn "/workspace"
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)

let response ?usage text =
  Llm.Response.make ~model ?usage (Llm.Message.Assistant.text text)

let tool_call ?(id = "call-1") ?(name = "read_file") () =
  Llm.Tool.Call.make ~id ~name ~input:(Json.object' []) ()

let finished_tool ?(id = "exec-1") ?(error = false) call text =
  let result = Llm.Tool.Result.text ~error call text in
  Session.Tool_claim.Finished.make
    ~id:(Session.Tool_claim.Id.of_string id)
    ~output:None result

let turn_finished ?(id = "turn-1") () =
  Session.Event.turn_finished
    ~turn:(Session.Turn.Id.of_string id)
    Session.Turn.Outcome.completed

let turn_started ?(id = "turn-1") () =
  Session.Event.turn_started
    (Session.Turn.make
       ~id:(Session.Turn.Id.of_string id)
       ~input:(Session.Turn.Input.user_text "Run.")
       ~model ())

let permission_denied ?(id = "permission-1") call =
  Session.Event.permission_resolved
    (Session.Permission.Resolved.deny
       ~id:(Session.Permission.Id.of_string id)
       (Llm.Tool.Result.text ~error:true call "denied"))

let permission_allowed ?(id = "permission-1") () =
  Session.Event.permission_resolved
    (Session.Permission.Resolved.allow_once
       ~id:(Session.Permission.Id.of_string id))

let usage ?(reasoning = 0) ?(cache_read = 0) ?(cache_write = 0) input output =
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ~cache_write ()

let empty_log_is_zero () =
  let metrics = Metrics.of_events [] in
  equal metrics_value ~msg:"empty metrics" Metrics.empty metrics

let sums_responses_and_usage () =
  let first = usage ~reasoning:3 ~cache_read:5 7 11 in
  let second = usage ~cache_write:13 17 19 in
  let metrics =
    Metrics.of_events
      [
        Session.Event.response_appended (response ~usage:first "first");
        Session.Event.response_appended (response "missing usage");
        Session.Event.response_appended (response ~usage:second "second");
      ]
  in
  equal int ~msg:"responses" 3 metrics.Metrics.responses;
  equal
    (testable ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal ())
    ~msg:"usage sum"
    (usage ~reasoning:3 ~cache_read:5 ~cache_write:13 24 30)
    metrics.Metrics.usage

let counts_turns_tools_failures_and_denials () =
  let read = tool_call ~id:"call-read" ~name:"read_file" () in
  let shell = tool_call ~id:"call-shell" ~name:"shell" () in
  let edit = tool_call ~id:"call-edit" ~name:"edit_file" () in
  let metrics =
    Metrics.of_events
      [
        turn_finished ~id:"turn-1" ();
        Session.Event.tool_claim_finished
          (finished_tool ~id:"exec-read-1" read "ok");
        Session.Event.tool_claim_finished
          (finished_tool ~id:"exec-shell" ~error:true shell "failed");
        Session.Event.tool_claim_finished
          (finished_tool ~id:"exec-read-2" read "ok");
        Session.Event.tool_claim_finished
          (finished_tool ~id:"exec-edit" edit "ok");
        Session.Event.message_appended
          (Llm.Message.tool_result
             (Llm.Tool.Result.text ~error:true
                (tool_call ~id:"call-rejected" ~name:"edit_file" ())
                "invalid input for tool edit_file"));
        Session.Event.message_appended
          (Llm.Message.tool_result (Llm.Tool.Result.text read "fine"));
        permission_allowed ~id:"permission-allowed" ();
        permission_denied ~id:"permission-denied" edit;
        turn_finished ~id:"turn-2" ();
      ]
  in
  equal int ~msg:"turns" 2 metrics.Metrics.turns;
  equal int ~msg:"tool calls" 4 metrics.Metrics.tool_calls;
  equal int ~msg:"tool failures" 1 metrics.Metrics.tool_failures;
  equal int ~msg:"tool rejections" 1 metrics.Metrics.tool_rejections;
  equal
    (list (pair string int))
    ~msg:"tool calls by name"
    [ ("edit_file", 1); ("read_file", 2); ("shell", 1) ]
    metrics.Metrics.tool_calls_by_name;
  equal int ~msg:"permission denials" 1 metrics.Metrics.permission_denials

let projects_from_validated_session () =
  let events =
    [
      turn_started ();
      Session.Event.response_appended
        (response ~usage:(usage ~cache_read:2 3 5) "ok");
      turn_finished ();
    ]
  in
  let session =
    match
      Session.make
        ~id:(Session.Id.of_string "metrics-session")
        ~metadata:
          (Session.Metadata.make ~cwd ~created_at:(time 1) ~updated_at:(time 1)
             ())
        ~events
    with
    | Ok session -> session
    | Error error ->
        failf "session reconstruction failed: %a" Session.Error.pp error
  in
  let metrics = Metrics.of_session session in
  equal int ~msg:"session responses" 1 metrics.Metrics.responses;
  equal int ~msg:"session turns" 1 metrics.Metrics.turns;
  equal
    (testable ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal ())
    ~msg:"session usage" (usage ~cache_read:2 3 5) metrics.Metrics.usage

let codec_roundtrip () =
  let call = tool_call ~name:"shell" () in
  let metrics =
    Metrics.of_events
      [
        Session.Event.response_appended
          (response ~usage:(usage ~cache_read:2 3 5) "ok");
        Session.Event.tool_claim_finished
          (finished_tool ~id:"exec-shell" call "ok");
        permission_denied call;
        turn_finished ();
      ]
  in
  let json = encode Metrics.jsont metrics in
  equal metrics_value ~msg:"metrics roundtrip" metrics
    (decode Metrics.jsont json)

let expect_decode_error msg json =
  match Json.decode Metrics.jsont json with
  | Ok _ -> failf "%s: expected decode error" msg
  | Error _ -> ()

let codec_rejects_invalid_counts () =
  let metrics_json ?(responses = 0) ?(turns = 0) ?(tool_calls = 1)
      ?(tool_failures = 0)
      ?(tool_calls_by_name =
        [
          json_object
            [ ("name", Json.string "read_file"); ("count", Json.int 1) ];
        ]) ?(permission_denials = 0) () =
    json_object
      [
        ("usage", encode Llm.Usage.jsont Llm.Usage.zero);
        ("responses", Json.int responses);
        ("turns", Json.int turns);
        ("tool_calls", Json.int tool_calls);
        ("tool_failures", Json.int tool_failures);
        ("tool_rejections", Json.int 0);
        ("tool_calls_by_name", Json.list tool_calls_by_name);
        ("permission_denials", Json.int permission_denials);
      ]
  in
  expect_decode_error "negative response count"
    (metrics_json ~responses:(-1) ());
  expect_decode_error "tool failures exceed tool calls"
    (metrics_json ~tool_failures:2 ());
  expect_decode_error "unsorted tool names"
    (metrics_json
       ~tool_calls_by_name:
         [
           json_object [ ("name", Json.string "shell"); ("count", Json.int 1) ];
           json_object
             [ ("name", Json.string "read_file"); ("count", Json.int 1) ];
         ]
       ());
  expect_decode_error "zero tool count"
    (metrics_json
       ~tool_calls_by_name:
         [
           json_object
             [ ("name", Json.string "read_file"); ("count", Json.int 0) ];
         ]
       ())

let () =
  run "spice.session.metrics"
    [
      test "empty log is zero" empty_log_is_zero;
      test "sums responses and usage" sums_responses_and_usage;
      test "counts turns tools failures and denials"
        counts_turns_tools_failures_and_denials;
      test "projects from validated session" projects_from_validated_session;
      test "codec roundtrip" codec_roundtrip;
      test "codec rejects invalid counts" codec_rejects_invalid_counts;
    ]
