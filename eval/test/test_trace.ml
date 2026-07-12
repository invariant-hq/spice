(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Eval = Spice_eval
module Trace = Spice_eval_trace.Trace
module Metrics = Spice_eval_trace.Trace_metrics
module Timing = Spice_eval_trace.Timing
module Session = Spice_session
module Llm = Spice_llm
module Options = Spice_llm.Request.Options
module Permission = Spice_permission
module Json = Jsont.Json

(* Fixtures *)

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5"
let cwd = Spice_path.Abs.of_string_exn "/workspace"
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)
let turn_id = Session.Turn.Id.of_string

let session events =
  match
    Session.make
      ~id:(Session.Id.of_string "trace-session")
      ~metadata:
        (Session.Metadata.make ~cwd ~created_at:(time 1) ~updated_at:(time 1) ())
      ~events
  with
  | Ok session -> session
  | Error error ->
      failf "session reconstruction failed: %a" Session.Error.pp error

let trace ?timing events = Trace.of_session ?timing (session events)

let path_input path =
  Json.object' [ Json.mem (Json.name "path") (Json.string path) ]

let command_input command =
  Json.object' [ Json.mem (Json.name "command") (Json.string command) ]

let call ?(id = "call") ~name input = Llm.Tool.Call.make ~id ~name ~input ()

let tool_decl name =
  Llm.Tool.make ~name ~input_schema:Llm.Tool.no_input_schema ()

let turn_started ?(options = Options.default) ?(declarations = [])
    ?(host_tools = []) id =
  Session.Event.turn_started
    (Session.Turn.make ~id
       ~input:(Session.Turn.Input.user_text "Go.")
       ~model ~options
       ~declarations:(List.map tool_decl declarations)
       ~host_tools ~max_steps:max_int ())

let turn_finished id =
  Session.Event.turn_finished ~turn:id Session.Turn.Outcome.completed

let response ?usage calls =
  Session.Event.response_appended
    (Llm.Response.make ~model ?usage
       (Llm.Message.Assistant.make
          (List.map Llm.Message.Assistant.tool_call calls)))

let text_response ?usage text =
  Session.Event.response_appended
    (Llm.Response.make ~model ?usage (Llm.Message.Assistant.text text))

let usage ?(reasoning = 0) ?(cache_read = 0) ?(cache_write = 0) input output =
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ~cache_write ()

(* Executed tool claim of [call], producing [text] with error flag [error]. *)
let claim ~turn claim_id call ~error text =
  let id = Session.Tool_claim.Id.of_string claim_id in
  [
    Session.Event.tool_claim_started
      (Session.Tool_claim.Started.make ~id ~turn ~call);
    Session.Event.tool_claim_finished
      (Session.Tool_claim.Finished.make ~id ~output:None
         (Llm.Tool.Result.text ~error call text));
  ]

let direct_result ~error call text =
  Session.Event.message_appended
    (Llm.Message.tool_result (Llm.Tool.Result.text ~error call text))

let permission_denied ?(id = "permission-1") call =
  Session.Event.permission_resolved
    (Session.Permission.Resolved.deny
       ~id:(Session.Permission.Id.of_string id)
       (Llm.Tool.Result.text ~error:true call "denied"))

let permission_requested ?(id = "permission-1") ~turn call =
  let access = Permission.Access.custom "tool.trace" in
  let request = Permission.Request.of_accesses [ access ] in
  let review =
    match
      Permission.Policy.Review.restore request
        (Permission.Access.Set.singleton access)
    with
    | Ok review -> review
    | Error _ -> failf "permission review reconstruction failed"
  in
  Session.Event.permission_requested
    (Session.Permission.Requested.of_review
       ~id:(Session.Permission.Id.of_string id)
       ~turn ~tool_call:call review)

(* A single-turn fixture whose one response issues [entries]: each is a call
   with its result text and error flag, executed via a claim. *)
let executed ?usage ?options ?declarations ?host_tools ?(turn = "turn-1")
    entries =
  let tid = turn_id turn in
  let calls = List.map (fun (c, _, _) -> c) entries in
  let claims =
    List.concat
      (List.mapi
         (fun index (c, error, text) ->
           claim ~turn:tid (Printf.sprintf "claim-%d" index) c ~error text)
         entries)
  in
  session
    (turn_started ?options ?declarations ?host_tools tid
     :: response ?usage calls :: claims
    @ [ turn_finished tid ])

let call_names calls = List.map Trace.Call.name calls

let call_statuses calls =
  List.map (fun c -> Trace.Call.status_to_string (Trace.Call.status c)) calls

(* Codec helpers *)

let encode codec value =
  match Json.encode codec value with
  | Ok json -> json
  | Error message -> failf "encode failed: %s" message

let decode codec json =
  match Json.decode codec json with
  | Ok value -> value
  | Error message -> failf "decode failed: %s" message

(* A two-response turn: a read that succeeds and a failing shell build, then a
   final text response. Exercises step and call joining, usage attribution, and
   most metric lanes. *)
let rich_events () =
  let c1 = call ~id:"c1" ~name:"read_file" (path_input "lib/a.ml") in
  let c2 = call ~id:"c2" ~name:"shell" (command_input "dune build @runtest") in
  let tid = turn_id "turn-1" in
  [
    turn_started ~declarations:[ "read_file"; "shell" ]
      ~options:(Options.make ~reasoning_effort:Options.Reasoning_effort.High ())
      tid;
    response ~usage:(usage ~reasoning:5 ~cache_read:10 100 20) [ c1; c2 ];
  ]
  @ claim ~turn:tid "claim-read" c1 ~error:false "content A"
  @ claim ~turn:tid "claim-shell" c2 ~error:true "build failed"
  @ [ text_response ~usage:(usage 150 30) "done"; turn_finished tid ]

(* Tests *)

let rich_trace () =
  let t = trace (rich_events ()) in
  equal int ~msg:"steps" 2 (List.length (Trace.steps t));
  equal (list string) ~msg:"call names" [ "read_file"; "shell" ]
    (call_names (Trace.calls t));
  equal (list string) ~msg:"call statuses" [ "ok"; "failed" ]
    (call_statuses (Trace.calls t));
  equal (list string) ~msg:"declared tools" [ "read_file"; "shell" ]
    (Trace.declared_tools t);
  (* Per-response usage attribution: the first step carries its own usage. *)
  match Trace.steps t with
  | first :: _ ->
      equal (option int) ~msg:"first step input total" (Some 110)
        (Option.map Llm.Usage.input_total (Trace.Step.usage first))
  | [] -> failf "no steps"

let metrics_on_known_fixture () =
  let m = Metrics.of_trace (trace (rich_events ())) in
  equal int ~msg:"responses" 2 m.Metrics.responses;
  equal int ~msg:"tool calls" 2 m.Metrics.tool_calls;
  equal int ~msg:"tool failures" 1 m.Metrics.tool_failures;
  equal int ~msg:"tool rejections" 0 m.Metrics.tool_rejections;
  equal int ~msg:"input tokens" 250 m.Metrics.input_tokens;
  equal int ~msg:"output tokens" 50 m.Metrics.output_tokens;
  equal int ~msg:"reasoning tokens" 5 m.Metrics.reasoning_tokens;
  equal int ~msg:"cache read tokens" 10 m.Metrics.cache_read_tokens;
  equal (option int) ~msg:"input first" (Some 110) m.Metrics.input_first;
  equal (option int) ~msg:"input last" (Some 150) m.Metrics.input_last;
  equal
    (option (Windtrap.float 1e-9))
    ~msg:"input growth mean" (Some 40.) m.Metrics.input_growth_mean;
  equal
    (option (Windtrap.float 1e-9))
    ~msg:"cache hit rate"
    (Some (10. /. 260.))
    m.Metrics.cache_hit_rate;
  equal
    (list (pair string int))
    ~msg:"calls by name"
    [ ("read_file", 1); ("shell", 1) ]
    m.Metrics.calls_by_name;
  equal int ~msg:"result bytes total" 21 m.Metrics.result_bytes_total;
  equal
    (list (pair string int))
    ~msg:"result bytes by name"
    [ ("read_file", 9); ("shell", 12) ]
    m.Metrics.result_bytes_by_name;
  equal int ~msg:"failure streak max" 1 m.Metrics.failure_streak_max;
  equal int ~msg:"segments" 1 m.Metrics.segments;
  equal
    (list (pair string int))
    ~msg:"shell families"
    [ ("dune build", 1) ]
    m.Metrics.shell_families;
  equal (option string) ~msg:"model" (Some "openai/gpt-5") m.Metrics.model;
  equal (option string) ~msg:"reasoning effort" (Some "high")
    m.Metrics.reasoning_effort;
  (* Codec round-trips preserve the fields. *)
  let round = decode Metrics.jsont (encode Metrics.jsont m) in
  equal int ~msg:"codec responses" m.Metrics.responses round.Metrics.responses;
  equal int ~msg:"codec input tokens" m.Metrics.input_tokens
    round.Metrics.input_tokens;
  equal (option string) ~msg:"codec model" m.Metrics.model round.Metrics.model;
  equal
    (list (pair string int))
    ~msg:"codec shell families" m.Metrics.shell_families
    round.Metrics.shell_families

let host_tool_calls_excluded () =
  let executable = call ~id:"c1" ~name:"read_file" (path_input "lib/a.ml") in
  let host = call ~id:"c2" ~name:"todo" (Json.object' []) in
  let tid = turn_id "turn-1" in
  let events =
    [
      turn_started ~declarations:[ "read_file"; "todo" ] ~host_tools:[ "todo" ]
        tid;
      response [ executable; host ];
    ]
    @ claim ~turn:tid "claim-read" executable ~error:false "content"
    @ [ direct_result ~error:false host "todo updated"; turn_finished tid ]
  in
  let t = trace events in
  equal (list string) ~msg:"host call excluded" [ "read_file" ]
    (call_names (Trace.calls t))

let rejections_counted () =
  let c1 = call ~id:"c1" ~name:"edit_file" (path_input "lib/a.ml") in
  let c2 = call ~id:"c2" ~name:"write_file" (path_input "lib/b.ml") in
  let tid = turn_id "turn-1" in
  let events =
    [
      turn_started ~declarations:[ "edit_file"; "write_file" ] tid;
      response [ c1; c2 ];
      direct_result ~error:true c1 "invalid input";
      permission_requested ~id:"deny-c2" ~turn:tid c2;
      permission_denied ~id:"deny-c2" c2;
      turn_finished tid;
    ]
  in
  let t = trace events in
  let m = Metrics.of_trace t in
  equal (list string) ~msg:"rejected statuses" [ "rejected"; "rejected" ]
    (call_statuses (Trace.calls t));
  equal int ~msg:"tool calls" 0 m.Metrics.tool_calls;
  equal int ~msg:"tool rejections" 2 m.Metrics.tool_rejections

let segments_split_on_compaction () =
  let tid1 = turn_id "turn-1" and tid2 = turn_id "turn-2" in
  let replacement =
    match Llm.Transcript.of_list [ Llm.Message.user_text "Compacted." ] with
    | Ok transcript -> transcript
    | Error _ -> failf "transcript construction failed"
  in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.User_requested
      ~summary:"Compacted." ~transcript:replacement ()
  in
  let events =
    [
      turn_started tid1;
      text_response ~usage:(usage 100 10) "first";
      turn_finished tid1;
      Session.Event.compaction_installed compaction;
      turn_started tid2;
      text_response ~usage:(usage 120 12) "second";
      turn_finished tid2;
    ]
  in
  let t = trace events in
  equal int ~msg:"segment count" 2 (List.length (Trace.segments t));
  equal (list int) ~msg:"steps per segment" [ 1; 1 ]
    (List.map List.length (Trace.segments t));
  equal (list int) ~msg:"step segment indices" [ 0; 1 ]
    (List.map Trace.Step.segment_index (Trace.steps t))

let repeated_call_count () =
  let repeats_of doc =
    (Metrics.of_trace (Trace.of_session doc)).Metrics.repeated_call_count
  in
  let repeated =
    executed ~declarations:[ "shell" ]
      (List.init 4 (fun index ->
           ( call
               ~id:(Printf.sprintf "c%d" index)
               ~name:"shell" (command_input "ls"),
             false,
             "listing" )))
  in
  (* Four identical calls: three beyond the first in their group. *)
  equal int ~msg:"repeats beyond first" 3 (repeats_of repeated);
  let distinct =
    executed ~declarations:[ "shell" ]
      [
        (call ~id:"a" ~name:"shell" (command_input "ls"), false, "x");
        (call ~id:"b" ~name:"shell" (command_input "pwd"), false, "y");
      ]
  in
  equal int ~msg:"distinct calls do not repeat" 0 (repeats_of distinct)

let failure_streak_count () =
  let streak error_run =
    executed ~declarations:[ "shell" ]
      (List.init error_run (fun index ->
           ( call
               ~id:(Printf.sprintf "c%d" index)
               ~name:"shell"
               (command_input (Printf.sprintf "cmd-%d" index)),
             true,
             "failed" )))
  in
  let streak_of doc =
    (Metrics.of_trace (Trace.of_session doc)).Metrics.failure_streak_max
  in
  equal int ~msg:"streak of three" 3 (streak_of (streak 3));
  equal int ~msg:"streak of two" 2 (streak_of (streak 2))

let reread_count () =
  let reread =
    executed ~declarations:[ "read_file" ]
      [
        (call ~id:"r1" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
        (call ~id:"r2" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
      ]
  in
  let with_edit =
    executed
      ~declarations:[ "read_file"; "write_file" ]
      [
        (call ~id:"r1" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
        ( call ~id:"w1" ~name:"write_file" (path_input "lib/a.ml"),
          false,
          "wrote" );
        (call ~id:"r2" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
      ]
  in
  let rereads_of doc =
    (Metrics.of_trace (Trace.of_session doc)).Metrics.reread_count
  in
  equal int ~msg:"unchanged reread counted" 1 (rereads_of reread);
  equal int ~msg:"reread after edit not counted" 0 (rereads_of with_edit)

let shell_families () =
  let shells =
    executed ~declarations:[ "shell" ]
      [
        (call ~id:"s1" ~name:"shell" (command_input "git status"), false, "out");
        ( call ~id:"s2" ~name:"shell" (command_input "git commit -m x"),
          false,
          "out" );
        (call ~id:"s3" ~name:"shell" (command_input "ls"), false, "out");
      ]
  in
  let t = Trace.of_session shells in
  let expected = [ ("git commit", 1); ("git status", 1); ("ls", 1) ] in
  equal
    (list (pair string int))
    ~msg:"trace families" expected (Trace.shell_families t);
  equal
    (list (pair string int))
    ~msg:"metrics families" expected (Metrics.of_trace t).Metrics.shell_families;
  let no_shell =
    executed ~declarations:[ "read_file" ]
      [
        (call ~id:"r" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
      ]
  in
  equal
    (list (pair string int))
    ~msg:"no shell no families" []
    (Metrics.of_trace (Trace.of_session no_shell)).Metrics.shell_families

let timing_join () =
  let agent_jsonl =
    String.concat "\n"
      [
        {|{"type":"tool.started","tool_call_id":"c1"}|};
        {|{"type":"tool.finished","tool_call_id":"c1"}|};
        "";
      ]
  in
  let timing_jsonl =
    String.concat "\n"
      [ {|{"line":1,"ts_ms":1000}|}; {|{"line":2,"ts_ms":1500}|}; "" ]
  in
  let timing = Timing.of_artifacts ~agent_jsonl ~timing_jsonl in
  equal
    (option (pair (Windtrap.float 1e-9) (Windtrap.float 1e-9)))
    ~msg:"call interval"
    (Some (1000., 1500.))
    (Timing.call_interval timing ~tool_call_id:"c1");
  let doc =
    executed ~declarations:[ "read_file" ]
      [
        (call ~id:"c1" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
      ]
  in
  let t = Trace.of_session ~timing doc in
  (match Trace.calls t with
  | [ c ] ->
      equal
        (option (Windtrap.float 1e-9))
        ~msg:"call duration" (Some 0.5) (Trace.Call.duration_s c)
  | _ -> failf "expected one call");
  match Trace.steps t with
  | [ step ] ->
      equal
        (option (Windtrap.float 1e-9))
        ~msg:"step duration" (Some 0.5)
        (Trace.Step.duration_s step)
  | _ -> failf "expected one step"

(* The analyze subcommand decodes captured session.json with the same codec the
   session store writes; confirm a round-trip through it yields the same trace. *)
let decodes_from_json_document () =
  let document = session (rich_events ()) in
  let text =
    match Jsont_bytesrw.encode_string Session.jsont document with
    | Ok text -> text
    | Error message -> failf "session encode failed: %s" message
  in
  let decoded =
    match Jsont_bytesrw.decode_string Session.jsont text with
    | Ok session -> session
    | Error message -> failf "session decode failed: %s" message
  in
  let direct = Metrics.of_trace (Trace.of_session document) in
  let round = Metrics.of_trace (Trace.of_session decoded) in
  equal int ~msg:"decoded responses" direct.Metrics.responses
    round.Metrics.responses;
  equal int ~msg:"decoded tool calls" direct.Metrics.tool_calls
    round.Metrics.tool_calls;
  equal
    (list (pair string int))
    ~msg:"decoded calls by name" direct.Metrics.calls_by_name
    round.Metrics.calls_by_name

let digest_lists_declared_tools () =
  let doc =
    executed ~declarations:[ "shell"; "read_file" ]
      [
        (call ~id:"c1" ~name:"read_file" (path_input "lib/a.ml"), false, "body");
      ]
  in
  let rendered =
    Format.asprintf "%a"
      (fun ppf t -> Trace.pp_digest ppf t)
      (Trace.of_session doc)
  in
  let header =
    List.find_opt
      (fun line -> String.length line >= 6 && String.sub line 0 6 = "tools:")
      (String.split_on_char '\n' rendered)
  in
  equal (option string) ~msg:"declared tool catalog header"
    (Some "tools: read_file, shell") header

let markers_scan () =
  let hits text = Eval.Markers.scan text in
  is_true ~msg:"eval_calc matches" (hits "eval_calc" <> []);
  is_true ~msg:"_evals matches" (hits "_evals" <> []);
  is_true ~msg:"spice_eval_smoke matches" (hits "spice_eval_smoke" <> []);
  is_true ~msg:"case insensitive" (hits "EVAL_CALC" <> []);
  equal (list string) ~msg:"clean text has no markers" []
    (List.map
       (fun hit -> hit.Eval.Markers.term)
       (hits "a library named textkit"))

let () =
  Windtrap.run "spice.eval.trace"
    [
      test "reconstructs steps and calls" rich_trace;
      test "computes metrics on a known fixture" metrics_on_known_fixture;
      test "excludes host tool calls" host_tool_calls_excluded;
      test "counts rejections" rejections_counted;
      test "splits segments on compaction" segments_split_on_compaction;
      test "counts repeated calls" repeated_call_count;
      test "counts failure streaks" failure_streak_count;
      test "counts unchanged rereads" reread_count;
      test "breaks down shell families" shell_families;
      test "joins timing" timing_join;
      test "decodes from a json document" decodes_from_json_document;
      test "digest lists declared tools" digest_lists_declared_tools;
      test "marker scan" markers_scan;
    ]
