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

let session events =
  match
    Session.make ~id:(Session.Id.of_string "metrics-session")
      ~metadata:
        (Session.Metadata.make ~cwd ~created_at:(time 1) ~updated_at:(time 1) ())
      ~events
  with
  | Ok session -> session
  | Error error ->
      failf "session reconstruction failed: %a" Session.Error.pp error

let response ?usage text =
  Llm.Response.make ~model ?usage (Llm.Message.Assistant.text text)

let tool_call ?(id = "call-1") ?(name = "read_file") () =
  Llm.Tool.Call.make ~id ~name ~input:(Json.object' []) ()

let turn_finished ?(id = "turn-1") () =
  Session.Event.turn_finished
    ~turn:(Session.Turn.Id.of_string id)
    Session.Turn.Outcome.completed

let turn_started ?(id = "turn-1") () =
  Session.Event.turn_started
    (Session.Turn.make
       ~id:(Session.Turn.Id.of_string id)
       ~input:(Session.Turn.Input.user_text "Run.")
       ~model ~declarations:[] ~host_tools:[] ~max_steps:max_int ())

let permission_denied ?(id = "permission-1") call =
  Session.Event.permission_resolved
    (Session.Permission.Resolved.deny
       ~id:(Session.Permission.Id.of_string id)
       (Llm.Tool.Result.text ~error:true call "denied"))

let permission_requested ?(id = "permission-1") ~turn call =
  let access = Spice_permission.Access.custom "tool.metrics" in
  let request = Spice_permission.Request.of_accesses [ access ] in
  let review =
    match
      Spice_permission.Policy.Review.restore request
        (Spice_permission.Access.Set.singleton access)
    with
    | Ok review -> review
    | Error Spice_permission.Policy.Review.Empty_accesses ->
        failf "permission review failed: empty accesses"
    | Error (Spice_permission.Policy.Review.Access_not_in_request access) ->
        failf "permission review failed: %a not in request"
          Spice_permission.Access.pp access
  in
  Session.Event.permission_requested
    (Session.Permission.Requested.of_review
       ~id:(Session.Permission.Id.of_string id)
       ~turn ~tool_call:call review)

let usage ?(reasoning = 0) ?(cache_read = 0) ?(cache_write = 0) input output =
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ~cache_write ()

let empty_log_is_zero () =
  let metrics = Session.metrics (session []) in
  equal
    (testable ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal ())
    ~msg:"empty usage" Llm.Usage.zero metrics.Metrics.usage;
  equal int ~msg:"empty responses" 0 metrics.Metrics.responses;
  equal int ~msg:"empty turns" 0 metrics.Metrics.turns;
  equal int ~msg:"empty tool calls" 0 metrics.Metrics.tool_calls;
  equal int ~msg:"empty permission denials" 0
    metrics.Metrics.permission_denials

let sums_responses_and_usage () =
  let first = usage ~reasoning:3 ~cache_read:5 7 11 in
  let second = usage ~cache_write:13 17 19 in
  let metrics =
    Session.metrics
      (session
         [
           turn_started ~id:"turn-1" ();
           Session.Event.response_appended (response ~usage:first "first");
           turn_finished ~id:"turn-1" ();
           turn_started ~id:"turn-2" ();
           Session.Event.response_appended (response "missing usage");
           turn_finished ~id:"turn-2" ();
           turn_started ~id:"turn-3" ();
           Session.Event.response_appended (response ~usage:second "second");
           turn_finished ~id:"turn-3" ();
         ])
  in
  equal int ~msg:"responses" 3 metrics.Metrics.responses;
  equal
    (testable ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal ())
    ~msg:"usage sum"
    (usage ~reasoning:3 ~cache_read:5 ~cache_write:13 24 30)
    metrics.Metrics.usage

let counts_turns_tools_failures_and_denials () =
  let read = tool_call ~id:"call-read-1" ~name:"read_file" () in
  let shell = tool_call ~id:"call-shell" ~name:"shell" () in
  let read_again = tool_call ~id:"call-read-2" ~name:"read_file" () in
  let edit = tool_call ~id:"call-edit" ~name:"edit_file" () in
  let rejected = tool_call ~id:"call-rejected" ~name:"edit_file" () in
  let denied = tool_call ~id:"call-denied" ~name:"write_file" () in
  let turn = Session.Turn.Id.of_string "turn-1" in
  let claim id call ~error text =
    let id = Session.Tool_claim.Id.of_string id in
    [
      Session.Event.tool_claim_started
        (Session.Tool_claim.Started.make ~id ~turn ~call);
      Session.Event.tool_claim_finished
        (Session.Tool_claim.Finished.make ~id ~output:None
           (Llm.Tool.Result.text ~error call text));
    ]
  in
  let assistant =
    Llm.Message.Assistant.make
      (List.map Llm.Message.Assistant.tool_call
         [ read; shell; read_again; edit; rejected; denied ])
  in
  let metrics =
    let events =
      [
        turn_started ~id:"turn-1" ();
        Session.Event.response_appended (Llm.Response.make ~model assistant);
      ]
      @ claim "exec-read-1" read ~error:false "ok"
      @ claim "exec-shell" shell ~error:true "failed"
      @ claim "exec-read-2" read_again ~error:false "ok"
      @ claim "exec-edit" edit ~error:false "ok"
      @ [
          Session.Event.message_appended
            (Llm.Message.tool_result
               (Llm.Tool.Result.text ~error:true rejected
                  "invalid input for tool edit_file"));
          permission_requested ~id:"permission-denied" ~turn denied;
          permission_denied ~id:"permission-denied" denied;
          turn_finished ~id:"turn-1" ();
          turn_started ~id:"turn-2" ();
          Session.Event.response_appended (response "done");
          turn_finished ~id:"turn-2" ();
        ]
    in
    Session.metrics (session events)
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
  let metrics = Session.metrics (session events) in
  equal int ~msg:"session responses" 1 metrics.Metrics.responses;
  equal int ~msg:"session turns" 1 metrics.Metrics.turns;
  equal
    (testable ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal ())
    ~msg:"session usage" (usage ~cache_read:2 3 5) metrics.Metrics.usage

let codec_roundtrip () =
  let metrics =
    Session.metrics
      (session
         [
           turn_started ();
           Session.Event.response_appended
             (response ~usage:(usage ~cache_read:2 3 5) "ok");
           turn_finished ();
         ])
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
