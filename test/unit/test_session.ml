(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Session = Spice_session
module Llm = Spice_llm
module Permission = Spice_permission
module Json = Jsont.Json
module State = Session.State

let state_error = testable ~pp:State.Error.pp ~equal:( = ) ()
let session_error = testable ~pp:Session.Error.pp ~equal:( = ) ()

let turn_id_value =
  testable ~pp:Session.Turn.Id.pp ~equal:Session.Turn.Id.equal ()

let outcome_value =
  testable ~pp:Session.Turn.Outcome.pp ~equal:Session.Turn.Outcome.equal ()

let model_value = testable ~pp:Llm.Model.pp ~equal:Llm.Model.equal ()
let message_list_value = testable ~pp:(fun _ _ -> ()) ~equal:( = ) ()

let expect_decode_error msg codec json =
  match Json.decode codec json with
  | Ok _ -> failf "%s: expected decode error" msg
  | Error _ -> ()

let expect_error msg expected = function
  | Ok _ -> failf "%s: expected state error" msg
  | Error error -> equal state_error ~msg expected error

let expect_replay_error msg expected = function
  | Ok _ -> failf "%s: expected replay error" msg
  | Error error -> equal state_error ~msg expected (State.Replay_error.cause error)

let expect_session_error msg expected = function
  | Ok _ -> failf "%s: expected session error" msg
  | Error error -> equal session_error ~msg expected error

let expect_invalid_transcript msg check = function
  | Ok _ -> failf "%s: expected transcript error" msg
  | Error (State.Error.Transcript error) -> check error
  | Error error ->
      failf "%s: unexpected state error: %a" msg State.Error.pp error

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5"
let other_model = Llm.Model.make ~provider ~api ~id:"gpt-5-mini"
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)
let cwd = Spice_path.Abs.of_string_exn "/workspace"
let turn_id id = Session.Turn.Id.of_string id

let turn ?(id = "turn-1") ?(input = Session.Turn.Input.user_text "Refactor.")
    ?(model = model) () =
  Session.Turn.make ~id:(turn_id id) ~input ~model ~declarations:[]
    ~host_tools:[] ~max_steps:max_int ()

let response ?(model = model) assistant = Llm.Response.make ~model assistant
let assistant_text text = Llm.Message.Assistant.text text

let tool_call ?(id = "call-1") ?(name = "read_file") () =
  Llm.Tool.Call.make ~id ~name ~input:(Json.object' []) ()

let assistant_tool_call call =
  Llm.Message.Assistant.make [ Llm.Message.Assistant.tool_call call ]

let tool_result call text =
  Llm.Message.tool_result (Llm.Tool.Result.text call text)

let transcript messages =
  match Llm.Transcript.of_list messages with
  | Ok transcript -> transcript
  | Error error ->
      failf "transcript construction failed: %a" Llm.Transcript.Error.pp error

let extension_access name = Permission.Access.custom name

let permission_request ?(id = "permission-1") ?(grantable = true) ~turn
    ~tool_call access =
  let request = Permission.Request.of_accesses ~grantable [ access ] in
  let ask =
    match
      Permission.Policy.Review.restore request
        [ (access, Permission.Policy.Review.Unmatched) ]
    with
    | Ok ask -> ask
    | Error Permission.Policy.Review.Empty_accesses ->
        failf "permission review reconstruction failed: empty accesses"
    | Error (Permission.Policy.Review.Access_not_in_request access) ->
        failf "permission review reconstruction failed: %a not in request"
          Permission.Access.pp access
  in
  Session.Permission.Requested.of_review
    ~id:(Session.Permission.Id.of_string id)
    ~turn ~tool_call ask

let event_equality_ignores_retained_output () =
  let call = tool_call ~id:"equal-call" ~name:"equal_tool" () in
  let value_id : (int -> int) Type.Id.t = Type.Id.make () in
  let output =
    Spice_tool.Output.make ~text:"done"
      ~value:(Spice_tool.Output.pack value_id (fun value -> value + 1))
      ()
  in
  let finished =
    Session.Tool_claim.Finished.make
      ~id:(Session.Tool_claim.Id.of_string "equal-claim")
      ~output:(Some output) (Llm.Tool.Result.text call "done")
  in
  let event = Session.Event.tool_claim_finished finished in
  (match Session.Event.equal event event with
  | true -> ()
  | false -> failf "event equality is not reflexive"
  | exception Invalid_argument message ->
      failf "event equality raised on retained evidence: %s" message);
  let decoded = decode Session.Event.jsont (encode Session.Event.jsont event) in
  is_true ~msg:"event equality follows its durable JSON projection"
    (Session.Event.equal event decoded)

let durable_events_and_session_round_trip () =
  let declarations =
    List.map
      (fun name ->
        Llm.Tool.make ~name ~input_schema:Llm.Tool.no_input_schema ())
      [ "review_tool"; "read_file"; "host_tool" ]
  in
  let turn =
    Session.Turn.make ~id:(turn_id "turn-roundtrip")
      ~input:(Session.Turn.Input.user_text "Handle the calls.") ~model
      ~declarations ~host_tools:[ "host_tool" ] ~max_steps:8 ()
  in
  let reviewed = tool_call ~id:"call-reviewed" ~name:"review_tool" () in
  let claimed = tool_call ~id:"call-claimed" ~name:"read_file" () in
  let host = tool_call ~id:"call-host" ~name:"host_tool" () in
  let permission =
    permission_request ~id:"permission-roundtrip"
      ~turn:(Session.Turn.id turn) ~tool_call:reviewed
      (extension_access "tool.roundtrip")
  in
  let claim =
    Session.Tool_claim.Started.make
      ~id:(Session.Tool_claim.Id.of_string "claim-roundtrip")
      ~turn:(Session.Turn.id turn) ~call:claimed
  in
  let replacement = transcript [ Llm.Message.user_text "Compacted history." ] in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.User_requested
      ~summary:"Compacted history." ~transcript:replacement ()
  in
  let events =
    [
      Session.Event.turn_started turn;
      Session.Event.response_appended
        (response
           (Llm.Message.Assistant.make
              (List.map Llm.Message.Assistant.tool_call
                 [ reviewed; claimed; host ])));
      Session.Event.permission_requested permission;
      Session.Event.permission_resolved
        (Session.Permission.Resolved.deny
           ~id:(Session.Permission.Requested.id permission)
           (Llm.Tool.Result.text ~error:true reviewed "denied"));
      Session.Event.tool_claim_started claim;
      Session.Event.tool_claim_finished
        (Session.Tool_claim.Finished.make
           ~id:(Session.Tool_claim.Started.id claim) ~output:None
           (Llm.Tool.Result.text claimed "contents"));
      Session.Event.message_appended
        (Llm.Message.tool_result (Llm.Tool.Result.text host "answered"));
      Session.Event.turn_finished ~turn:(Session.Turn.id turn)
        Session.Turn.Outcome.completed;
      Session.Event.compaction_installed compaction;
    ]
  in
  List.iter
    (fun event ->
      let decoded = decode Session.Event.jsont (encode Session.Event.jsont event) in
      is_true ~msg:"event constructor round-trips durably"
        (Session.Event.equal event decoded))
    events;
  let metadata =
    Session.Metadata.make ~title:"Round trip" ~cwd ~created_at:(time 1)
      ~updated_at:(time 2) ()
  in
  let session =
    match
      Session.make ~id:(Session.Id.of_string "session-roundtrip") ~metadata
        ~events
    with
    | Ok session -> session
    | Error error -> failf "session construction failed: %a" Session.Error.pp error
  in
  let decoded = decode Session.jsont (encode Session.jsont session) in
  is_true ~msg:"session id round-trips"
    (Session.Id.equal (Session.id session) (Session.id decoded));
  is_true ~msg:"session metadata round-trips"
    (Session.Metadata.equal (Session.metadata session) (Session.metadata decoded));
  is_true ~msg:"session events round-trip in order"
    (List.equal Session.Event.equal (Session.events session)
       (Session.events decoded));
  let state = Session.state decoded in
  equal int ~msg:"round-trip rebuilds the turn" 1
    (List.length (State.turns state));
  equal int ~msg:"round-trip retains permission history" 1
    (List.length (State.permissions state));
  equal int ~msg:"round-trip retains claim history" 1
    (List.length (State.tool_claims state));
  is_true ~msg:"round-trip transcript is request-ready"
    (Llm.Transcript.is_ready (State.transcript state));
  equal message_list_value ~msg:"compaction replacement is reconstructed"
    (Llm.Transcript.messages replacement)
    (Llm.Transcript.messages (State.transcript state))

let state events =
  match State.of_events events with
  | Ok state -> state
  | Error error ->
      failf "state reconstruction failed: %a" State.Replay_error.pp error

let apply event state =
  match State.apply event state with
  | Ok state -> state
  | Error error -> failf "state apply failed: %a" State.Error.pp error

let turn_starts_and_finishes () =
  let turn = turn () in
  let state =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_text "Done."));
        Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          Session.Turn.Outcome.completed;
      ]
  in
  equal (option turn_id_value) ~msg:"no active turn" None
    (State.active_turn_id state);
  equal int ~msg:"transcript has user and assistant messages" 2
    (Llm.Transcript.length (State.transcript state));
  equal (list turn_id_value) ~msg:"turn order"
    [ Session.Turn.id turn ]
    (List.map Session.Turn.id (State.turns state));
  equal (option outcome_value) ~msg:"turn outcome"
    (Some Session.Turn.Outcome.completed)
    (State.turn_outcome (Session.Turn.id turn) state)

let state_projects_active_turn_and_phase () =
  let turn = turn () in
  let started = state [ Session.Event.turn_started turn ] in
  equal
    (option (testable ~pp:Session.Turn.pp ~equal:Session.Turn.equal ()))
    ~msg:"active turn value" (Some turn) (State.active_turn started);
  equal (option turn_id_value) ~msg:"active turn id"
    (Some (Session.Turn.id turn))
    (State.active_turn_id started);
  (match State.phase started with
  | State.Phase.Active -> ()
  | phase -> failf "ready turn phase: %a" State.Phase.pp phase);
  let host_declaration =
    Llm.Tool.make ~name:"host_tool" ~input_schema:Llm.Tool.no_input_schema ()
  in
  let host_turn =
    Session.Turn.make ~id:(turn_id "turn-host")
      ~input:(Session.Turn.Input.user_text "Ask.") ~model
      ~declarations:[ host_declaration ]
      ~host_tools:[ "host_tool" ] ~max_steps:max_int ()
  in
  let host_call = tool_call ~id:"host-call" ~name:"host_tool" () in
  let waiting =
    state
      [
        Session.Event.turn_started host_turn;
        Session.Event.response_appended
          (response (assistant_tool_call host_call));
      ]
  in
  let expected =
    Session.Waiting.host_tool ~turn:(Session.Turn.id host_turn) host_call
  in
  equal
    (option
       (testable ~pp:Session.Waiting.pp ~equal:Session.Waiting.equal ()))
    ~msg:"host waiting value" (Some expected) (State.waiting waiting);
  (match State.phase waiting with
  | State.Phase.Waiting actual when Session.Waiting.equal expected actual -> ()
  | phase -> failf "host waiting phase: %a" State.Phase.pp phase);
  (match State.phase State.empty with
  | State.Phase.Idle -> ()
  | phase -> failf "empty state phase: %a" State.Phase.pp phase)

let host_wait_serializes_later_durable_work () =
  let host_declaration =
    Llm.Tool.make ~name:"host_tool" ~input_schema:Llm.Tool.no_input_schema ()
  in
  let turn =
    Session.Turn.make ~id:(turn_id "turn-serial-host")
      ~input:(Session.Turn.Input.user_text "Handle both.") ~model
      ~declarations:[ host_declaration ] ~host_tools:[ "host_tool" ]
      ~max_steps:max_int ()
  in
  let host_call = tool_call ~id:"host-first" ~name:"host_tool" () in
  let executable = tool_call ~id:"exec-second" ~name:"read_file" () in
  let assistant =
    Llm.Message.Assistant.make
      [
        Llm.Message.Assistant.tool_call host_call;
        Llm.Message.Assistant.tool_call executable;
      ]
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response assistant);
      ]
  in
  let expected =
    State.Error.Turn
      (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn))
  in
  let claim =
    Session.Tool_claim.Started.make
      ~id:(Session.Tool_claim.Id.of_string "claim-second")
      ~turn:(Session.Turn.id turn) ~call:executable
  in
  expect_error "claim cannot pass host waiting" expected
    (State.apply (Session.Event.tool_claim_started claim) blocked);
  let request =
    permission_request ~id:"permission-second" ~turn:(Session.Turn.id turn)
      ~tool_call:executable (extension_access "tool.second")
  in
  expect_error "permission cannot pass host waiting" expected
    (State.apply (Session.Event.permission_requested request) blocked)

let reducer_transition_errors_are_structured () =
  let turn = turn () in
  let turn_id = Session.Turn.id turn in
  let call = tool_call ~id:"call-transition" ~name:"read_file" () in
  let other_call = tool_call ~id:"call-other" ~name:"read_file" () in
  let started = [ Session.Event.turn_started turn ] in
  let pending_call =
    started
    @ [ Session.Event.response_appended (response (assistant_tool_call call)) ]
  in
  let completed =
    Session.Event.turn_finished ~turn:turn_id Session.Turn.Outcome.completed
  in
  let finished_turn =
    started
    @ [
        Session.Event.response_appended (response (assistant_text "Done."));
        completed;
      ]
  in
  let permission =
    permission_request ~id:"permission-transition" ~turn:turn_id ~tool_call:call
      (extension_access "tool.transition")
  in
  let permission_id = Session.Permission.Requested.id permission in
  let permission_event = Session.Event.permission_requested permission in
  let pending_permission = pending_call @ [ permission_event ] in
  let permission_allowed =
    Session.Event.permission_resolved
      (Session.Permission.Resolved.allow_once ~id:permission_id)
  in
  let resolved_permission = pending_permission @ [ permission_allowed ] in
  let claim =
    Session.Tool_claim.Started.make
      ~id:(Session.Tool_claim.Id.of_string "claim-transition") ~turn:turn_id
      ~call
  in
  let claim_id = Session.Tool_claim.Started.id claim in
  let claim_event = Session.Event.tool_claim_started claim in
  let pending_claim = pending_call @ [ claim_event ] in
  let finished_claim =
    Session.Tool_claim.Finished.make ~id:claim_id ~output:None
      (Llm.Tool.Result.text call "contents")
  in
  let claim_finished_event = Session.Event.tool_claim_finished finished_claim in
  let finished_claim_events = pending_claim @ [ claim_finished_event ] in
  let check label prefix event expected =
    expect_error label expected (State.apply event (state prefix))
  in
  check "active turn precedes duplicate turn" started
    (Session.Event.turn_started turn)
    (State.Error.Turn (State.Error.Turn.Active turn_id));
  check "duplicate turn is rejected after finish" finished_turn
    (Session.Event.turn_started turn)
    (State.Error.Turn (State.Error.Turn.Duplicate turn_id));
  check "unknown turn precedes lifecycle state" [] completed
    (State.Error.Turn (State.Error.Turn.Unknown turn_id));
  check "finished turn precedes missing active turn" finished_turn completed
    (State.Error.Turn (State.Error.Turn.Finished turn_id));
  check "idle-only message rejects an active turn" started
    (Session.Event.message_appended (Llm.Message.developer "note"))
    (State.Error.Turn (State.Error.Turn.Active turn_id));
  check "duplicate permission precedes waiting checks" pending_permission
    permission_event
    (State.Error.Permission (State.Error.Permission.Duplicate permission_id));
  check "unknown permission precedes lifecycle state" [] permission_allowed
    (State.Error.Permission (State.Error.Permission.Unknown permission_id));
  let mismatched_denial =
    Session.Event.permission_resolved
      (Session.Permission.Resolved.deny ~id:permission_id
         (Llm.Tool.Result.text ~error:true other_call "denied"))
  in
  check "resolved permission precedes result mismatch" resolved_permission
    mismatched_denial
    (State.Error.Permission (State.Error.Permission.Not_pending permission_id));
  check "duplicate claim precedes waiting checks" pending_claim claim_event
    (State.Error.Tool_claim (State.Error.Tool_claim.Duplicate claim_id));
  check "unknown claim precedes result checks" [] claim_finished_event
    (State.Error.Tool_claim (State.Error.Tool_claim.Unknown claim_id));
  let mismatched_finish =
    Session.Event.tool_claim_finished
      (Session.Tool_claim.Finished.make ~id:claim_id ~output:None
         (Llm.Tool.Result.text other_call "wrong"))
  in
  check "finished claim precedes result mismatch" finished_claim_events
    mismatched_finish
    (State.Error.Tool_claim (State.Error.Tool_claim.Not_pending claim_id));
  check "claim requires a pending transcript call" started claim_event
    (State.Error.Tool_claim
       (State.Error.Tool_claim.Tool_call_not_pending
          { execution = claim_id; call_id = Llm.Tool.Call.id call }));
  let before = state pending_claim in
  expect_error "rejected duplicate leaves input reusable"
    (State.Error.Tool_claim (State.Error.Tool_claim.Duplicate claim_id))
    (State.apply claim_event before);
  let recovered = apply claim_finished_event before in
  let expected = state finished_claim_events in
  equal message_list_value ~msg:"recovery transcript matches clean replay"
    (Llm.Transcript.messages (State.transcript expected))
    (Llm.Transcript.messages (State.transcript recovered));
  let equal_claim_record (started_a, finished_a) (started_b, finished_b) =
    Session.Tool_claim.Started.equal started_a started_b
    && Option.equal Session.Tool_claim.Finished.equal finished_a finished_b
  in
  is_true ~msg:"recovery claim history matches clean replay"
    (List.equal equal_claim_record (State.tool_claims expected)
       (State.tool_claims recovered))

let final_text_projects_latest_assistant () =
  equal (option string) ~msg:"empty state has no final text" None
    (State.final_text State.empty);
  let tool_only =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended
          (response (assistant_tool_call (tool_call ())));
      ]
  in
  equal (option string) ~msg:"tool-only assistant carries no final text" None
    (State.final_text tool_only);
  let single =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response (assistant_text "Done."));
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
      ]
  in
  equal (option string) ~msg:"single assistant text" (Some "Done.")
    (State.final_text single);
  equal (option string) ~msg:"single turn final text" (Some "Done.")
    (State.turn_final_text (turn_id "turn-1") single);
  let multi_block =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended
          (response
             (Llm.Message.Assistant.make
                [
                  Llm.Message.Assistant.text_part "line 1";
                  Llm.Message.Assistant.text_part "line 2";
                ]));
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
      ]
  in
  equal (option string) ~msg:"text blocks joined with newline"
    (Some "line 1\nline 2")
    (State.final_text multi_block);
  equal (option string) ~msg:"multi-block turn final text"
    (Some "line 1\nline 2")
    (State.turn_final_text (turn_id "turn-1") multi_block);
  let two_turns =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response (assistant_text "first"));
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
        Session.Event.turn_started
          (turn ~id:"turn-2" ~input:Session.Turn.Input.continue ());
        Session.Event.response_appended (response (assistant_text "second"));
        Session.Event.turn_finished ~turn:(turn_id "turn-2")
          Session.Turn.Outcome.completed;
      ]
  in
  equal (option string) ~msg:"most recent assistant text wins" (Some "second")
    (State.final_text two_turns);
  equal (option string) ~msg:"first turn keeps its final text" (Some "first")
    (State.turn_final_text (turn_id "turn-1") two_turns);
  equal (option string) ~msg:"second turn keeps its final text" (Some "second")
    (State.turn_final_text (turn_id "turn-2") two_turns);
  let whitespace_turn =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response (assistant_text "first"));
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
        Session.Event.turn_started
          (turn ~id:"turn-2" ~input:Session.Turn.Input.continue ());
        Session.Event.response_appended (response (assistant_text "   "));
        Session.Event.turn_finished ~turn:(turn_id "turn-2")
          Session.Turn.Outcome.completed;
      ]
  in
  equal (option string) ~msg:"latest prose skips whitespace-only response"
    (Some "first")
    (State.final_text whitespace_turn);
  equal (option string) ~msg:"turn final text does not borrow from earlier turn"
    None
    (State.turn_final_text (turn_id "turn-2") whitespace_turn)

let compaction_replaces_transcript () =
  let turn = turn () in
  let before =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended
          (response (assistant_text "I changed the parser."));
        Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          Session.Turn.Outcome.completed;
      ]
  in
  let replacement_messages =
    [ Llm.Message.user_text "Summary: parser changes are complete." ]
  in
  let replacement = transcript replacement_messages in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.User_requested
      ~summary:"Parser changes are complete." ~transcript:replacement ()
  in
  let after = apply (Session.Event.compaction_installed compaction) before in
  equal message_list_value ~msg:"compaction replaces model replay transcript"
    replacement_messages
    (Llm.Transcript.messages (State.transcript after));
  equal int ~msg:"previous replay transcript was longer" 2
    (Llm.Transcript.length (State.transcript before));
  equal
    (option
       (testable ~pp:Session.Compaction.pp ~equal:Session.Compaction.equal ()))
    ~msg:"latest compaction is retained" (Some compaction)
    (State.latest_compaction after);
  equal int ~msg:"one installed compaction" 1
    (List.length (State.compactions after))

let reason_to_string_is_the_stable_tag () =
  equal (list string) ~msg:"reason tags match the jsont spelling"
    [
      "user_requested";
      "context_pressure";
      "context_overflow";
      "model_downshift";
    ]
    (List.map Session.Compaction.Reason.to_string
       [
         Session.Compaction.Reason.User_requested;
         Session.Compaction.Reason.Context_pressure;
         Session.Compaction.Reason.Context_overflow;
         Session.Compaction.Reason.Model_downshift;
       ])

let latest_model_follows_turns () =
  equal (option model_value) ~msg:"empty state has no latest model" None
    (State.latest_model (state []));
  let active = state [ Session.Event.turn_started (turn ()) ] in
  equal (option model_value) ~msg:"active turn's model" (Some model)
    (State.latest_model active);
  let finished =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response (assistant_text "Done."));
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
        Session.Event.turn_started (turn ~id:"turn-2" ~model:other_model ());
      ]
  in
  equal (option model_value) ~msg:"most recently started turn's model"
    (Some other_model)
    (State.latest_model finished)

let usage_value = testable ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal ()
let baseline_usage state = Option.map fst (State.replay_usage state)

let growth_length state =
  match State.replay_usage state with
  | None -> List.length (Llm.Transcript.messages (State.transcript state))
  | Some (_, growth) -> List.length growth

let replay_usage_tracks_latest_response () =
  let usage = Llm.Usage.make ~input:100 ~output:7 () in
  let turn1 = turn () in
  let started = state [ Session.Event.turn_started turn1 ] in
  equal (option usage_value) ~msg:"no baseline before any response" None
    (baseline_usage started);
  equal int ~msg:"growth covers the whole replay without a baseline" 1
    (growth_length started);
  let with_usage =
    apply
      (Session.Event.response_appended
         (Llm.Response.make ~model ~usage (assistant_text "Done.")))
      started
  in
  equal (option usage_value) ~msg:"baseline set by response usage" (Some usage)
    (baseline_usage with_usage);
  equal int ~msg:"baseline covers the transcript at the response" 0
    (growth_length with_usage);
  let next_turn =
    with_usage
    |> apply
         (Session.Event.turn_finished ~turn:(Session.Turn.id turn1)
            Session.Turn.Outcome.completed)
    |> apply (Session.Event.turn_started (turn ~id:"turn-2" ()))
  in
  equal int ~msg:"messages after the baseline are growth" 1
    (growth_length next_turn);
  let without_usage =
    apply
      (Session.Event.response_appended (response (assistant_text "More.")))
      next_turn
  in
  equal (option usage_value)
    ~msg:"responses without usage keep the previous baseline" (Some usage)
    (baseline_usage without_usage);
  equal int ~msg:"growth accumulates past usage-free responses" 2
    (growth_length without_usage)

let replay_usage_cleared_by_compaction () =
  let turn1 = turn () in
  let before =
    state
      [
        Session.Event.turn_started turn1;
        Session.Event.response_appended
          (Llm.Response.make ~model
             ~usage:(Llm.Usage.make ~input:50 ~output:5 ())
             (assistant_text "Done."));
        Session.Event.turn_finished ~turn:(Session.Turn.id turn1)
          Session.Turn.Outcome.completed;
      ]
  in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.Context_pressure
      ~summary:"Summary."
      ~transcript:(transcript [ Llm.Message.user_text "Summary." ])
      ()
  in
  let after = apply (Session.Event.compaction_installed compaction) before in
  is_true ~msg:"compaction clears the usage baseline"
    (Option.is_none (State.replay_usage after));
  equal int ~msg:"growth is the whole replacement replay" 1
    (growth_length after)

let compaction_preserves_active_turn () =
  let turn = turn () in
  let before = state [ Session.Event.turn_started turn ] in
  let replacement =
    transcript [ Llm.Message.user_text "Summary: active turn." ]
  in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.Context_pressure
      ~summary:"Active turn." ~transcript:replacement ()
  in
  let after = apply (Session.Event.compaction_installed compaction) before in
  equal (option turn_id_value) ~msg:"active turn remains active"
    (Some (Session.Turn.id turn))
    (State.active_turn_id after);
  equal message_list_value ~msg:"active compaction replaces transcript"
    (Llm.Transcript.messages replacement)
    (Llm.Transcript.messages (State.transcript after));
  equal
    (option
       (testable ~pp:Session.Compaction.pp ~equal:Session.Compaction.equal ()))
    ~msg:"latest compaction is retained" (Some compaction)
    (State.latest_compaction after)

let compaction_requires_ready_current_transcript () =
  let turn = turn () in
  let call = tool_call () in
  let pending =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
      ]
  in
  let replacement =
    transcript [ Llm.Message.user_text "Summary: interrupted." ]
  in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.Context_pressure
      ~summary:"Interrupted." ~transcript:replacement ()
  in
  expect_invalid_transcript "compaction rejects pending current transcript"
    (function
      | Llm.Transcript.Error.Pending_tool_results [ pending ] ->
          equal string ~msg:"pending call id" (Llm.Tool.Call.id call)
            (Llm.Tool.Call.id pending)
      | error ->
          failf "unexpected transcript error: %a" Llm.Transcript.Error.pp error)
    (State.apply (Session.Event.compaction_installed compaction) pending)

let compaction_requires_ready_replacement_transcript () =
  let call = tool_call () in
  let replacement =
    transcript [ Llm.Message.assistant (assistant_tool_call call) ]
  in
  expect_invalid_arg "compaction rejects pending replacement transcript"
    (fun () ->
      Session.Compaction.make ~reason:Session.Compaction.Reason.Context_pressure
        ~summary:"Pending replacement." ~transcript:replacement ())

let compaction_metadata_round_trips () =
  let replacement =
    transcript [ Llm.Message.user_text "Summary: parser work." ]
  in
  let tokens =
    Session.Compaction.Token_estimate.make ~before:1200 ~after:300
      ~summary_input:900 ~summary_output:180 ()
  in
  let range =
    Session.Compaction.Range.make ~summarized_messages:12
      ~retained_tail_messages:4
  in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.Context_overflow
      ~summary:"Parser work summarized." ~transcript:replacement ~model ~tokens
      ~range ()
  in
  let decoded =
    decode Session.Compaction.jsont (encode Session.Compaction.jsont compaction)
  in
  is_true ~msg:"compaction round-trips with metadata"
    (Session.Compaction.equal compaction decoded);
  equal (option model_value) ~msg:"summary model retained" (Some model)
    (Session.Compaction.model decoded);
  equal
    (option
       (testable ~pp:Session.Compaction.Token_estimate.pp
          ~equal:Session.Compaction.Token_estimate.equal ()))
    ~msg:"token metadata retained" (Some tokens)
    (Session.Compaction.tokens decoded);
  equal
    (option
       (testable ~pp:Session.Compaction.Range.pp
          ~equal:Session.Compaction.Range.equal ()))
    ~msg:"range metadata retained" (Some range)
    (Session.Compaction.range decoded)

let compaction_rejects_invalid_metadata () =
  let replacement =
    transcript [ Llm.Message.user_text "Summary: invalid metadata." ]
  in
  expect_invalid_arg "negative token estimate" (fun () ->
      Session.Compaction.Token_estimate.make ~before:(-1) ());
  expect_invalid_arg "empty token estimate" (fun () ->
      Session.Compaction.Token_estimate.make ());
  expect_invalid_arg "negative range" (fun () ->
      Session.Compaction.Range.make ~summarized_messages:0
        ~retained_tail_messages:(-1));
  expect_invalid_arg "empty summary" (fun () ->
      Session.Compaction.make ~reason:Session.Compaction.Reason.User_requested
        ~summary:"" ~transcript:replacement ())

let clean_finish_rejects_pending_tool_calls () =
  let turn = turn () in
  let call = tool_call () in
  let state =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
      ]
  in
  expect_invalid_transcript "completed turn needs request-ready transcript"
    (function
      | Llm.Transcript.Error.Pending_tool_results [ pending ] ->
          equal string ~msg:"pending call id" (Llm.Tool.Call.id call)
            (Llm.Tool.Call.id pending)
      | error ->
          failf "unexpected transcript error: %a" Llm.Transcript.Error.pp error)
    (State.apply
       (Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          Session.Turn.Outcome.completed)
       state)

let tool_results_require_active_turn () =
  let call = tool_call () in
  expect_replay_error "tool result without active turn"
    (State.Error.Turn State.Error.Turn.No_active)
    (State.of_events
       [ Session.Event.message_appended (tool_result call "contents") ])

let response_model_must_match_turn () =
  let turn = turn () in
  expect_replay_error "response model mismatch"
    (State.Error.Turn
       (State.Error.Turn.Response_model_mismatch
          {
            turn = Session.Turn.id turn;
            expected = model;
            actual = other_model;
          }))
    (State.of_events
       [
         Session.Event.turn_started turn;
         Session.Event.response_appended
           (response ~model:other_model (assistant_text "Done."));
       ]);
  not_equal model_value ~msg:"test confirms models differ" model other_model

let permission_replies_update_grants () =
  let turn = turn () in
  let call = tool_call ~name:"tool_approve" () in
  let access = extension_access "tool.approve" in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:call access
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested request;
      ]
  in
  equal int ~msg:"one pending permission" 1
    (List.length (State.pending_permissions blocked));
  equal bool ~msg:"one waiting" true (Option.is_some (State.waiting blocked));
  equal int ~msg:"one permission record" 1
    (List.length (State.permissions blocked));
  equal
    (testable ~pp:(fun _ _ -> ()) ~equal:Llm.Tool.Call.equal ())
    ~msg:"permission stores blocked tool call" call
    (Session.Permission.Requested.tool_call request);
  expect_error "clean finish rejects waiting"
    (State.Error.Turn
       (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn)))
    (State.apply
       (Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          Session.Turn.Outcome.completed)
       blocked);
  let resolved =
    apply
      (Session.Event.permission_resolved
         (Session.Permission.Resolved.allow_session
            ~id:(Session.Permission.Requested.id request)))
      blocked
  in
  equal int ~msg:"permission no longer pending" 0
    (List.length (State.pending_permissions resolved));
  equal int ~msg:"resolved permission is retained" 1
    (List.length
       (List.filter
          (fun (_, resolved) -> Option.is_some resolved)
          (State.permissions resolved)));
  is_true ~msg:"allow-session reply updates grants"
    (Permission.Policy.Grants.allows (State.grants resolved) access)

let permission_request_requires_pending_tool_call () =
  let turn = turn () in
  let pending_call = tool_call ~id:"call-pending" ~name:"tool_pending" () in
  let other_call = tool_call ~id:"call-other" ~name:"tool_pending" () in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:other_call
      (extension_access "tool.pending")
  in
  expect_replay_error "permission rejects non-pending tool call"
    (State.Error.Permission
       (State.Error.Permission.Tool_call_not_pending
          {
            permission = Session.Permission.Requested.id request;
            call_id = Llm.Tool.Call.id other_call;
          }))
    (State.of_events
       [
         Session.Event.turn_started turn;
         Session.Event.response_appended
           (response (assistant_tool_call pending_call));
         Session.Event.permission_requested request;
       ])

let permission_requests_are_serial () =
  let turn = turn () in
  let call = tool_call ~name:"tool_serial" () in
  let first =
    permission_request ~id:"permission-first" ~turn:(Session.Turn.id turn)
      ~tool_call:call (extension_access "tool.serial")
  in
  let second =
    permission_request ~id:"permission-second" ~turn:(Session.Turn.id turn)
      ~tool_call:call (extension_access "tool.serial")
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested first;
      ]
  in
  expect_error "second permission request rejects unresolved waiting"
    (State.Error.Turn
       (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn)))
    (State.apply (Session.Event.permission_requested second) blocked)

let raw_tool_result_cannot_bypass_permission () =
  let turn = turn () in
  let call = tool_call ~name:"tool_owned" () in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:call
      (extension_access "tool.owned")
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested request;
      ]
  in
  expect_error "raw tool result cannot bypass permission"
    (State.Error.Permission
       (State.Error.Permission.Result_bypasses_permission
          {
            permission = Session.Permission.Requested.id request;
            call_id = Llm.Tool.Call.id call;
          }))
    (State.apply
       (Session.Event.message_appended (tool_result call "bypassed"))
       blocked)

let permission_request_json_requires_tool_call () =
  let turn = turn () in
  let call = tool_call ~name:"tool_json" () in
  let access = extension_access "tool.json" in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:call access
  in
  let decoded =
    decode Session.Permission.Requested.jsont
      (encode Session.Permission.Requested.jsont request)
  in
  is_true ~msg:"permission request round-trips"
    (Session.Permission.Requested.equal request decoded);
  let review_rule =
    Permission.Policy.Rule.review (Permission.Policy.Match.exact access)
  in
  let rule_review =
    match
      Permission.Policy.decide (Permission.Policy.make [ review_rule ])
        (Permission.Request.of_accesses [ access ])
    with
    | Permission.Policy.Decision.Review review -> review
    | Permission.Policy.Decision.Allowed
    | Permission.Policy.Decision.Denied _ ->
        failf "review rule did not produce a permission review"
  in
  let rule_request =
    Session.Permission.Requested.of_review
      ~id:(Session.Permission.Id.of_string "permission-rule")
      ~turn:(Session.Turn.id turn) ~tool_call:call rule_review
  in
  let rule_decoded =
    decode Session.Permission.Requested.jsont
      (encode Session.Permission.Requested.jsont rule_request)
  in
  is_true ~msg:"captured review rule round-trips"
    (Session.Permission.Requested.equal rule_request rule_decoded);
  let raw_request = Permission.Request.of_accesses [ access ] in
  let reasons =
    Json.list
      [
        json_object
          [
            ("access", encode Permission.Access.jsont access);
            ("reason", json_object [ ("kind", Json.string "unmatched") ]);
          ];
      ]
  in
  let missing_tool_call_json =
    json_object
      [
        ( "id",
          encode Session.Permission.Id.jsont
            (Session.Permission.Requested.id request) );
        ("turn", encode Session.Turn.Id.jsont (Session.Turn.id turn));
        ("request", encode Permission.Request.jsont raw_request);
        ("reasons", reasons);
      ]
  in
  expect_decode_error "permission request JSON requires tool_call"
    Session.Permission.Requested.jsont missing_tool_call_json

let terminal_turns_reject_unresolved_waiting () =
  let turn = turn () in
  let call = tool_call ~name:"tool_confirm" () in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:call
      (extension_access "tool.confirm")
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested request;
      ]
  in
  let expect_rejected label outcome =
    expect_error label
      (State.Error.Turn
         (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn)))
      (State.apply
         (Session.Event.turn_finished ~turn:(Session.Turn.id turn) outcome)
         blocked)
  in
  expect_rejected "failed turn rejects unresolved waiting"
    (Session.Turn.Outcome.failed ~message:"permission prompt cancelled");
  expect_rejected "interrupted turn rejects unresolved waiting"
    (Session.Turn.Outcome.interrupted ~reason:"cancelled" ~cancelled:true ())

let session_document_appends_and_tracks_state () =
  let turn = turn () in
  let session =
    Session.create
      ~id:(Session.Id.of_string "session-1")
      ~title:"Parser" ~cwd ~created_at:(time 1) ()
  in
  let session =
    match
      Session.Log.append_all
        [
          Session.Event.turn_started turn;
          Session.Event.response_appended (response (assistant_text "Done."));
          Session.Event.turn_finished ~turn:(Session.Turn.id turn)
            Session.Turn.Outcome.completed;
        ]
        session
    with
    | Ok session -> session
    | Error error -> failf "session append failed: %a" Session.Error.pp error
  in
  equal int ~msg:"events are retained" 3 (List.length (Session.events session));
  equal (option string) ~msg:"metadata title" (Some "Parser")
    (Session.Metadata.title (Session.metadata session));
  equal int ~msg:"state is derived from events" 2
    (Llm.Transcript.length (State.transcript (Session.state session)))

let append_paths_preserve_event_order () =
  let turn = turn () in
  let appended =
    [
      Session.Event.turn_started turn;
      Session.Event.response_appended (response (assistant_text "Done."));
      Session.Event.turn_finished ~turn:(Session.Turn.id turn)
        Session.Turn.Outcome.completed;
    ]
  in
  let fresh id =
    Session.create ~id:(Session.Id.of_string id) ~cwd ~created_at:(time 1) ()
  in
  let batch =
    match Session.Log.append_all appended (fresh "session-batch") with
    | Ok session -> session
    | Error error -> failf "batch append failed: %a" Session.Error.pp error
  in
  let incremental =
    List.fold_left
      (fun session event ->
        match Session.Log.append event session with
        | Ok session -> session
        | Error error ->
            failf "incremental append failed: %a" Session.Error.pp error)
      (fresh "session-incremental") appended
  in
  let same_events expected actual =
    List.equal Session.Event.equal (Session.events expected)
      (Session.events actual)
  in
  is_true ~msg:"batch and incremental append keep application order"
    (same_events batch incremental);
  let decoded = decode Session.jsont (encode Session.jsont batch) in
  is_true ~msg:"session JSON preserves chronological event order"
    (same_events batch decoded);
  let archived =
    match Session.archive batch with
    | Ok session -> session
    | Error error -> failf "archive failed: %a" Session.Error.pp error
  in
  match Session.Log.append_all [] archived with
  | Error error ->
      failf "empty append changed behavior: %a" Session.Error.pp error
  | Ok unchanged ->
      is_true ~msg:"empty append leaves inactive history unchanged"
        (same_events archived unchanged)

let replay_errors_locate_invalid_events () =
  let first_turn = turn ~id:"turn-located-first" () in
  let second_turn = turn ~id:"turn-located-second" () in
  let first = Session.Event.turn_started first_turn in
  let invalid = Session.Event.turn_started second_turn in
  let expected =
    State.Error.Turn (State.Error.Turn.Active (Session.Turn.id first_turn))
  in
  (match State.of_events [ first; invalid ] with
  | Ok _ -> failf "invalid replay succeeded"
  | Error error ->
      equal int ~msg:"batch-relative replay index" 1
        (State.Replay_error.index error);
      is_true ~msg:"replay error retains invalid event"
        (Session.Event.equal invalid (State.Replay_error.event error));
      equal state_error ~msg:"replay error retains structured cause" expected
        (State.Replay_error.cause error));
  let completed_turn = turn ~id:"turn-located-completed" () in
  let session =
    Session.create ~id:(Session.Id.of_string "session-located") ~cwd
      ~created_at:(time 1) ()
    |> Session.Log.append_all
         [
           Session.Event.turn_started completed_turn;
           Session.Event.response_appended (response (assistant_text "Done."));
           Session.Event.turn_finished ~turn:(Session.Turn.id completed_turn)
             Session.Turn.Outcome.completed;
         ]
    |> function
    | Ok session -> session
    | Error error -> failf "valid prefix failed: %a" Session.Error.pp error
  in
  match Session.Log.append_all [ first; invalid ] session with
  | Ok _ -> failf "invalid session append succeeded"
  | Error (Session.Error.Replay error) ->
      equal int ~msg:"absolute session-log index" 4
        (State.Replay_error.index error);
      is_true ~msg:"session error retains invalid event"
        (Session.Event.equal invalid (State.Replay_error.event error));
      equal state_error ~msg:"session error retains structured cause" expected
        (State.Replay_error.cause error)
  | Error error -> failf "unexpected session error: %a" Session.Error.pp error

let permission_denial_result_must_match_blocked_call () =
  let turn = turn () in
  let call = tool_call ~id:"permission-call" ~name:"tool_reviewed" () in
  let other_call = tool_call ~id:"other-call" ~name:"tool_reviewed" () in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:call
      (extension_access "tool.reviewed")
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested request;
      ]
  in
  let denied =
    Session.Permission.Resolved.deny
      ~id:(Session.Permission.Requested.id request)
      (Llm.Tool.Result.text ~error:true other_call "no")
  in
  expect_error "permission denial result mismatch"
    (State.Error.Permission
       (State.Error.Permission.Result_mismatch
          {
            permission = Session.Permission.Requested.id request;
            expected_call_id = Llm.Tool.Call.id call;
            expected_name = Llm.Tool.Call.name call;
            actual_call_id = Llm.Tool.Call.id other_call;
            actual_name = Llm.Tool.Call.name other_call;
          }))
    (State.apply (Session.Event.permission_resolved denied) blocked)

let permission_decision_eliminator () =
  let id = Session.Permission.Id.of_string "permission-decide" in
  let call = tool_call ~id:"decide-call" ~name:"tool_decide" () in
  let result = Llm.Tool.Result.text ~error:true call "denied" in
  (match
     Session.Permission.Resolved.decision
       (Session.Permission.Resolved.allow_once ~id)
   with
  | Session.Permission.Resolved.Allow Permission.Policy.Review.Once -> ()
  | _ -> failf "allow_once decides to Allow Once");
  (match
     Session.Permission.Resolved.decision
       (Session.Permission.Resolved.allow_session ~id)
   with
  | Session.Permission.Resolved.Allow Permission.Policy.Review.Session -> ()
  | _ -> failf "allow_session decides to Allow Session");
  (match
     Session.Permission.Resolved.decision
       (Session.Permission.Resolved.deny ~id result)
   with
  | Session.Permission.Resolved.Deny denied ->
      equal string ~msg:"deny carries the answering result's call id"
        (Llm.Tool.Call.id call)
        (Llm.Tool.Result.call_id denied)
  | Session.Permission.Resolved.Allow _ -> failf "deny decides to Deny");
  (* Provenance is orthogonal to the decision: allow answers are always by a
     reviewer; deny defaults to reviewer and records unattended when asked. *)
  let via_of r =
    match Session.Permission.Resolved.via r with
    | `Reviewer -> "reviewer"
    | `Unattended -> "unattended"
  in
  equal string ~msg:"allow_once provenance is reviewer" "reviewer"
    (via_of (Session.Permission.Resolved.allow_once ~id));
  equal string ~msg:"deny defaults to reviewer provenance" "reviewer"
    (via_of (Session.Permission.Resolved.deny ~id result));
  equal string ~msg:"unattended deny records its provenance" "unattended"
    (via_of (Session.Permission.Resolved.deny ~id ~via:`Unattended result))

let allow_once_leaves_session_grants_untouched () =
  (* Reducer contract for the [Allow Once] scope: unlike [Allow Session] (see
     [permission_replies_update_grants]), a one-shot allow adds no grant, so the
     next call to the same tool still requires review. This pins that grants are
     computed directly from the allow scope. *)
  let turn = turn () in
  let call = tool_call ~name:"tool_once" () in
  let access = extension_access "tool.once" in
  let request =
    permission_request ~turn:(Session.Turn.id turn) ~tool_call:call access
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested request;
      ]
  in
  let resolved =
    apply
      (Session.Event.permission_resolved
         (Session.Permission.Resolved.allow_once
            ~id:(Session.Permission.Requested.id request)))
      blocked
  in
  equal int ~msg:"permission no longer pending" 0
    (List.length (State.pending_permissions resolved));
  equal int ~msg:"resolved permission is retained" 1
    (List.length
       (List.filter
          (fun (_, resolved) -> Option.is_some resolved)
          (State.permissions resolved)));
  is_true ~msg:"one-shot allow adds no session grant"
    (not (Permission.Policy.Grants.allows (State.grants resolved) access))

let allow_session_respects_non_grantable_requests () =
  let turn = turn () in
  let call = tool_call ~name:"tool_session" () in
  let access = extension_access "tool.session" in
  let request =
    permission_request ~grantable:false ~turn:(Session.Turn.id turn)
      ~tool_call:call access
  in
  let blocked =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.permission_requested request;
      ]
  in
  let resolved =
    apply
      (Session.Event.permission_resolved
         (Session.Permission.Resolved.allow_session
            ~id:(Session.Permission.Requested.id request)))
      blocked
  in
  is_true ~msg:"allow-session adds no grant for a non-grantable request"
    (not (Permission.Policy.Grants.allows (State.grants resolved) access))

let tool_claim_blocks_until_finished () =
  let turn = turn () in
  let call = tool_call ~id:"exec-call-1" ~name:"read_file" () in
  let execution =
    Session.Tool_claim.Started.make
      ~id:(Session.Tool_claim.Id.of_string "execution-1")
      ~turn:(Session.Turn.id turn) ~call
  in
  let started =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.tool_claim_started execution;
      ]
  in
  equal int ~msg:"one pending execution" 1
    (List.length (State.pending_tool_claims started));
  equal bool ~msg:"one waiting" true (Option.is_some (State.waiting started));
  expect_error "clean finish rejects unfinished tool claim"
    (State.Error.Turn
       (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn)))
    (State.apply
       (Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          Session.Turn.Outcome.completed)
       started);
  expect_error "failed finish rejects unfinished tool claim"
    (State.Error.Turn
       (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn)))
    (State.apply
       (Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          (Session.Turn.Outcome.failed ~message:"tool failed"))
       started);
  expect_error "interrupted finish rejects unfinished tool claim"
    (State.Error.Turn
       (State.Error.Turn.Unresolved_waiting (Session.Turn.id turn)))
    (State.apply
       (Session.Event.turn_finished ~turn:(Session.Turn.id turn)
          (Session.Turn.Outcome.interrupted ~reason:"cancelled" ~cancelled:true
             ()))
       started);
  let finished =
    Session.Tool_claim.Finished.make
      ~id:(Session.Tool_claim.Started.id execution)
      ~output:None
      (Llm.Tool.Result.text call "file contents")
  in
  let ready = apply (Session.Event.tool_claim_finished finished) started in
  equal int ~msg:"execution no longer pending" 0
    (List.length (State.pending_tool_claims ready));
  is_true ~msg:"tool result answers the transcript"
    (Llm.Transcript.is_ready (State.transcript ready))

let raw_tool_result_cannot_bypass_claim () =
  let turn = turn () in
  let call = tool_call ~id:"claimed-call" ~name:"read_file" () in
  let execution =
    Session.Tool_claim.Started.make
      ~id:(Session.Tool_claim.Id.of_string "claimed-execution")
      ~turn:(Session.Turn.id turn) ~call
  in
  let claimed =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.tool_claim_started execution;
      ]
  in
  expect_error "raw tool result cannot bypass claim"
    (State.Error.Tool_claim
       (State.Error.Tool_claim.Result_bypasses_claim
          {
            execution = Session.Tool_claim.Started.id execution;
            call_id = Llm.Tool.Call.id call;
          }))
    (State.apply
       (Session.Event.message_appended (tool_result call "bypassed"))
       claimed)

let tool_claim_result_must_match_started_call () =
  let turn = turn () in
  let call = tool_call ~id:"exec-call-2" ~name:"read_file" () in
  let other_call = tool_call ~id:"other-call" ~name:"read_file" () in
  let execution =
    Session.Tool_claim.Started.make
      ~id:(Session.Tool_claim.Id.of_string "execution-2")
      ~turn:(Session.Turn.id turn) ~call
  in
  let started =
    state
      [
        Session.Event.turn_started turn;
        Session.Event.response_appended (response (assistant_tool_call call));
        Session.Event.tool_claim_started execution;
      ]
  in
  let finished =
    Session.Tool_claim.Finished.make
      ~id:(Session.Tool_claim.Started.id execution)
      ~output:None
      (Llm.Tool.Result.text other_call "wrong")
  in
  expect_error "tool claim result mismatch"
    (State.Error.Tool_claim
       (State.Error.Tool_claim.Result_mismatch
          {
            execution = Session.Tool_claim.Started.id execution;
            expected_call_id = Llm.Tool.Call.id call;
            expected_name = Llm.Tool.Call.name call;
            actual_call_id = Llm.Tool.Call.id other_call;
            actual_name = Llm.Tool.Call.name other_call;
          }))
    (State.apply (Session.Event.tool_claim_finished finished) started)

let finished_tool_claim_json_requires_output () =
  let call = tool_call ~id:"exec-call-json" ~name:"read_file" () in
  let execution_id = Session.Tool_claim.Id.of_string "execution-json" in
  let result = Llm.Tool.Result.text call "file contents" in
  let missing_output_json =
    json_object
      [
        ("id", encode Session.Tool_claim.Id.jsont execution_id);
        ("result", encode Llm.Tool.Result.jsont result);
      ]
  in
  expect_decode_error "finished tool claim JSON requires output"
    Session.Tool_claim.Finished.jsont missing_output_json

let archived_and_deleted_sessions_reject_appends () =
  let session =
    Session.create
      ~id:(Session.Id.of_string "session-archive")
      ~cwd ~created_at:(time 1) ()
  in
  let archived =
    match Session.archive session with
    | Ok session -> session
    | Error error -> failf "archive failed: %a" Session.Error.pp error
  in
  is_true ~msg:"metadata is archived"
    (Session.Metadata.is_archived (Session.metadata archived));
  expect_session_error "archived append" Session.Error.Archived
    (Session.Log.append (Session.Event.turn_started (turn ())) archived);
  let restored =
    match Session.restore archived with
    | Ok session -> session
    | Error error -> failf "restore failed: %a" Session.Error.pp error
  in
  is_true ~msg:"metadata is active"
    (Session.Metadata.is_active (Session.metadata restored));
  let deleted =
    match Session.delete restored with
    | Ok session -> session
    | Error error -> failf "delete failed: %a" Session.Error.pp error
  in
  is_true ~msg:"metadata is deleted"
    (Session.Metadata.is_deleted (Session.metadata deleted));
  expect_session_error "deleted append" Session.Error.Deleted
    (Session.Log.append (Session.Event.turn_started (turn ())) deleted);
  expect_session_error "deleted restore" Session.Error.Deleted
    (Session.restore deleted)

let delete_is_idempotent_for_active_tombstone () =
  let id = Session.Id.of_string "active-tombstone" in
  let metadata =
    Session.Metadata.make ~status:Session.Metadata.Status.Deleted ~cwd
      ~created_at:(time 1) ~updated_at:(time 1) ()
  in
  let active =
    match
      Session.make ~id ~metadata
        ~events:[ Session.Event.turn_started (turn ()) ]
    with
    | Ok session -> session
    | Error error ->
        failf "session reconstruction failed: %a" Session.Error.pp error
  in
  match Session.delete active with
  | Error error ->
      failf "deleting an already-deleted tombstone failed: %a" Session.Error.pp
        error
  | Ok deleted ->
      is_true ~msg:"session remains deleted"
        (Session.Metadata.is_deleted (Session.metadata deleted))

let archive_rejects_active_turn () =
  let turn = turn () in
  let session =
    Session.create
      ~id:(Session.Id.of_string "session-active")
      ~cwd ~created_at:(time 1) ()
    |> fun session ->
    match Session.Log.append (Session.Event.turn_started turn) session with
    | Ok session -> session
    | Error error -> failf "turn append failed: %a" Session.Error.pp error
  in
  expect_session_error "archive active turn"
    (Session.Error.Active_turn (Session.Turn.id turn))
    (Session.archive session)

let fork_records_parent_lineage () =
  let parent_id = Session.Id.of_string "session-parent" in
  let child_id = Session.Id.of_string "session-child" in
  let turn = turn () in
  let parent =
    Session.create ~id:parent_id ~cwd ~created_at:(time 1) () |> fun session ->
    match
      Session.Log.append_all
        [
          Session.Event.turn_started turn;
          Session.Event.response_appended (response (assistant_text "Done."));
          Session.Event.turn_finished ~turn:(Session.Turn.id turn)
            Session.Turn.Outcome.completed;
        ]
        session
    with
    | Ok session -> session
    | Error error -> failf "parent append failed: %a" Session.Error.pp error
  in
  let child =
    match
      Session.fork ~id:child_id ~title:"Child" ~cwd ~created_at:(time 2) parent
    with
    | Ok session -> session
    | Error error -> failf "fork failed: %a" Session.Error.pp error
  in
  equal (option string) ~msg:"child title" (Some "Child")
    (Session.Metadata.title (Session.metadata child));
  equal int ~msg:"child copied events"
    (List.length (Session.events parent))
    (List.length (Session.events child));
  match Session.Metadata.fork (Session.metadata child) with
  | None -> failf "child has no fork lineage"
  | Some fork ->
      equal
        (testable ~pp:Session.Id.pp ~equal:Session.Id.equal ())
        ~msg:"parent id" parent_id fork.Session.Metadata.Forked_from.parent;
      equal int ~msg:"copied event count"
        (List.length (Session.events parent))
        fork.Session.Metadata.Forked_from.copied_events

let fork_rejects_active_turn () =
  let turn = turn () in
  let parent =
    Session.create
      ~id:(Session.Id.of_string "session-active-parent")
      ~cwd ~created_at:(time 1) ()
    |> fun session ->
    match Session.Log.append (Session.Event.turn_started turn) session with
    | Ok session -> session
    | Error error -> failf "parent append failed: %a" Session.Error.pp error
  in
  expect_session_error "fork active turn"
    (Session.Error.Active_turn (Session.Turn.id turn))
    (Session.fork
       ~id:(Session.Id.of_string "session-active-child")
       ~cwd ~created_at:(time 2) parent)

let session_of ?(id = "session-rewind") events =
  let session =
    Session.create ~id:(Session.Id.of_string id) ~cwd ~created_at:(time 1) ()
  in
  match Session.Log.append_all events session with
  | Ok session -> session
  | Error error -> failf "session build failed: %a" Session.Error.pp error

let turn_events ?input ~id text =
  let turn = turn ~id ?input () in
  [
    Session.Event.turn_started turn;
    Session.Event.response_appended (response (assistant_text text));
    Session.Event.turn_finished ~turn:(Session.Turn.id turn)
      Session.Turn.Outcome.completed;
  ]

(* turn-1, an idle developer message, then turn-2. Event indices:
   0 turn_started t1, 1 response, 2 turn_finished t1,
   3 message_appended developer, 4 turn_started t2, 5 response,
   6 turn_finished t2. The idle message at index 3 makes
   [after_turn turn-1] (cut 3) and [before_turn turn-2] (cut 4) distinct. *)
let idle_session () =
  session_of
    (turn_events ~id:"turn-1" "one"
    @ [ Session.Event.message_appended (Llm.Message.developer "note") ]
    @ turn_events ~id:"turn-2"
        ~input:(Session.Turn.Input.user_text "Again.")
        "two")

let anchor_names_turn_and_edge () =
  let before = Session.Anchor.before_turn (turn_id "turn-1") in
  let after = Session.Anchor.after_turn (turn_id "turn-2") in
  equal turn_id_value ~msg:"before_turn names its turn" (turn_id "turn-1")
    (Session.Anchor.turn before);
  (match Session.Anchor.edge before with
  | Session.Anchor.Before -> ()
  | Session.Anchor.After -> failf "before_turn should have the Before edge");
  (match Session.Anchor.edge after with
  | Session.Anchor.After -> ()
  | Session.Anchor.Before -> failf "after_turn should have the After edge");
  is_true ~msg:"same turn and edge are equal"
    (Session.Anchor.equal before
       (Session.Anchor.before_turn (turn_id "turn-1")));
  is_true ~msg:"a different edge is not equal"
    (not
       (Session.Anchor.equal before
          (Session.Anchor.after_turn (turn_id "turn-1"))));
  is_true ~msg:"a different turn is not equal"
    (not
       (Session.Anchor.equal before
          (Session.Anchor.before_turn (turn_id "turn-2"))));
  is_true ~msg:"before anchor round-trips through jsont"
    (Session.Anchor.equal before
       (decode Session.Anchor.jsont (encode Session.Anchor.jsont before)));
  is_true ~msg:"after anchor round-trips through jsont"
    (Session.Anchor.equal after
       (decode Session.Anchor.jsont (encode Session.Anchor.jsont after)))

let resolve_anchor_cuts_at_boundaries () =
  let session = idle_session () in
  let resolve anchor =
    match Session.resolve_anchor anchor session with
    | Ok n -> n
    | Error error -> failf "resolve failed: %a" Session.Error.pp error
  in
  equal int ~msg:"before the first turn is the empty prefix" 0
    (resolve (Session.Anchor.before_turn (turn_id "turn-1")));
  equal int ~msg:"after turn-1 cuts just past its finish" 3
    (resolve (Session.Anchor.after_turn (turn_id "turn-1")));
  equal int ~msg:"before turn-2 keeps the idle message" 4
    (resolve (Session.Anchor.before_turn (turn_id "turn-2")));
  is_true ~msg:"adjacent edges do not coincide across an idle message"
    (resolve (Session.Anchor.after_turn (turn_id "turn-1"))
    < resolve (Session.Anchor.before_turn (turn_id "turn-2")));
  equal int ~msg:"after the last turn is the whole log"
    (List.length (Session.events session))
    (resolve (Session.Anchor.after_turn (turn_id "turn-2")))

let first_turn_prefix_keeps_idle_events () =
  let idle = Session.Event.message_appended (Llm.Message.developer "preamble") in
  let session = session_of (idle :: turn_events ~id:"turn-1" "one") in
  let anchor = Session.Anchor.before_turn (turn_id "turn-1") in
  (match Session.resolve_anchor anchor session with
  | Ok copied -> equal int ~msg:"first-turn prefix includes the preamble" 1 copied
  | Error error -> failf "resolve failed: %a" Session.Error.pp error);
  let rewound =
    match
      Session.rewind ~id:(Session.Id.of_string "session-preamble") ~cwd
        ~created_at:(time 2) anchor session
    with
    | Ok session -> session
    | Error error -> failf "rewind failed: %a" Session.Error.pp error
  in
  match Session.events rewound with
  | [ kept ] ->
      is_true ~msg:"rewind retains the exact idle event"
        (Session.Event.equal idle kept)
  | events -> failf "expected one retained event, got %d" (List.length events)

let resolve_anchor_error_taxonomy () =
  let session = idle_session () in
  expect_session_error "unknown turn on a Before anchor"
    (Session.Error.Unknown_turn (turn_id "turn-404"))
    (Session.resolve_anchor
       (Session.Anchor.before_turn (turn_id "turn-404"))
       session);
  expect_session_error "unknown turn on an After anchor"
    (Session.Error.Unknown_turn (turn_id "turn-404"))
    (Session.resolve_anchor
       (Session.Anchor.after_turn (turn_id "turn-404"))
       session);
  let active =
    session_of ~id:"session-active"
      [ Session.Event.turn_started (turn ~id:"turn-live" ()) ]
  in
  expect_session_error "After an unfinished turn is rejected"
    (Session.Error.Turn_not_finished (turn_id "turn-live"))
    (Session.resolve_anchor
       (Session.Anchor.after_turn (turn_id "turn-live"))
       active)

let dropped_turns_is_edge_uniform () =
  let session = idle_session () in
  let dropped anchor =
    match Session.dropped_turns anchor session with
    | Ok ids -> ids
    | Error error -> failf "dropped_turns failed: %a" Session.Error.pp error
  in
  equal (list turn_id_value) ~msg:"before turn-1 drops both turns"
    [ turn_id "turn-1"; turn_id "turn-2" ]
    (dropped (Session.Anchor.before_turn (turn_id "turn-1")));
  equal (list turn_id_value) ~msg:"after turn-1 keeps it and drops later turns"
    [ turn_id "turn-2" ]
    (dropped (Session.Anchor.after_turn (turn_id "turn-1")));
  equal (list turn_id_value) ~msg:"before turn-2 drops only turn-2"
    [ turn_id "turn-2" ]
    (dropped (Session.Anchor.before_turn (turn_id "turn-2")));
  equal (list turn_id_value) ~msg:"after the last turn drops nothing" []
    (dropped (Session.Anchor.after_turn (turn_id "turn-2")))

let rewind_past_compaction_uncompacts () =
  let replacement = transcript [ Llm.Message.user_text "Summary." ] in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.User_requested
      ~summary:"Summary." ~transcript:replacement ()
  in
  let session =
    session_of ~id:"session-compaction"
      (turn_events ~id:"turn-1" "I changed the parser."
      @ [ Session.Event.compaction_installed compaction ]
      @ [
          Session.Event.turn_started
            (turn ~id:"turn-2" ~input:Session.Turn.Input.continue ());
          Session.Event.response_appended (response (assistant_text "more"));
          Session.Event.turn_finished ~turn:(turn_id "turn-2")
            Session.Turn.Outcome.completed;
        ])
  in
  let child anchor =
    match
      Session.rewind
        ~id:(Session.Id.of_string "session-child")
        ~cwd ~created_at:(time 2) anchor session
    with
    | Ok child -> child
    | Error error -> failf "rewind failed: %a" Session.Error.pp error
  in
  let uncompacted = child (Session.Anchor.after_turn (turn_id "turn-1")) in
  equal int ~msg:"rewinding before the compaction revives the full transcript" 2
    (Llm.Transcript.length (State.transcript (Session.state uncompacted)));
  equal int ~msg:"the un-compacted child has no installed compaction" 0
    (List.length (State.compactions (Session.state uncompacted)));
  let compacted = child (Session.Anchor.before_turn (turn_id "turn-2")) in
  equal int ~msg:"rewinding after the compaction keeps the summary transcript" 1
    (Llm.Transcript.length (State.transcript (Session.state compacted)));
  equal int ~msg:"the compacted child retains the installed compaction" 1
    (List.length (State.compactions (Session.state compacted)))

let rewind_records_prefix_lineage () =
  let session = idle_session () in
  let parent_id = Session.id session in
  let anchor = Session.Anchor.before_turn (turn_id "turn-2") in
  let expected =
    match Session.resolve_anchor anchor session with
    | Ok n -> n
    | Error error -> failf "resolve failed: %a" Session.Error.pp error
  in
  let child =
    match
      Session.rewind
        ~id:(Session.Id.of_string "session-child")
        ~title:"Child" ~cwd ~created_at:(time 2) anchor session
    with
    | Ok child -> child
    | Error error -> failf "rewind failed: %a" Session.Error.pp error
  in
  equal int ~msg:"child keeps exactly the resolved prefix" expected
    (List.length (Session.events child));
  equal (option turn_id_value) ~msg:"child replays to an idle state" None
    (State.active_turn_id (Session.state child));
  equal (option string) ~msg:"child title" (Some "Child")
    (Session.Metadata.title (Session.metadata child));
  match Session.Metadata.fork (Session.metadata child) with
  | None -> failf "child has no fork lineage"
  | Some fork ->
      equal
        (testable ~pp:Session.Id.pp ~equal:Session.Id.equal ())
        ~msg:"lineage parent id" parent_id
        fork.Session.Metadata.Forked_from.parent;
      equal int ~msg:"lineage copied event count" expected
        fork.Session.Metadata.Forked_from.copied_events

let rewind_at_last_boundary_equals_fork () =
  let session = idle_session () in
  let forked =
    match
      Session.fork
        ~id:(Session.Id.of_string "session-fork")
        ~cwd ~created_at:(time 2) session
    with
    | Ok session -> session
    | Error error -> failf "fork failed: %a" Session.Error.pp error
  in
  let rewound =
    match
      Session.rewind
        ~id:(Session.Id.of_string "session-rewound")
        ~cwd ~created_at:(time 2)
        (Session.Anchor.after_turn (turn_id "turn-2"))
        session
    with
    | Ok session -> session
    | Error error -> failf "rewind failed: %a" Session.Error.pp error
  in
  equal int ~msg:"rewind to the last boundary copies the whole log"
    (List.length (Session.events forked))
    (List.length (Session.events rewound));
  let copied session =
    match Session.Metadata.fork (Session.metadata session) with
    | Some fork -> fork.Session.Metadata.Forked_from.copied_events
    | None -> failf "session has no fork lineage"
  in
  equal int ~msg:"fork and last-boundary rewind copy the same count"
    (copied forked) (copied rewound)

let rewind_refuses_active_and_unknown () =
  let session = idle_session () in
  expect_session_error "rewind on an unknown turn"
    (Session.Error.Unknown_turn (turn_id "turn-404"))
    (Session.rewind
       ~id:(Session.Id.of_string "session-child")
       ~cwd ~created_at:(time 2)
       (Session.Anchor.before_turn (turn_id "turn-404"))
       session);
  let active =
    session_of ~id:"session-active"
      (turn_events ~id:"turn-1" "one"
      @ [ Session.Event.turn_started (turn ~id:"turn-live" ()) ])
  in
  (* The guard is on the parent: even a Before anchor that would itself drop the
     active turn is refused while the parent has one (spec §6.2/§13.7). *)
  expect_session_error "rewind refuses a parent with an active turn"
    (Session.Error.Active_turn (turn_id "turn-live"))
    (Session.rewind
       ~id:(Session.Id.of_string "session-child")
       ~cwd ~created_at:(time 2)
       (Session.Anchor.before_turn (turn_id "turn-live"))
       active)

let () =
  run "spice.session"
    [
      test "turn starts and finishes" turn_starts_and_finishes;
      test "state projects active turn and phase"
        state_projects_active_turn_and_phase;
      test "host wait serializes later durable work"
        host_wait_serializes_later_durable_work;
      test "reducer transition errors are structured"
        reducer_transition_errors_are_structured;
      test "event equality ignores retained output"
        event_equality_ignores_retained_output;
      test "durable events and session round trip"
        durable_events_and_session_round_trip;
      test "compaction replaces transcript" compaction_replaces_transcript;
      test "compaction reason to_string is the stable tag"
        reason_to_string_is_the_stable_tag;
      test "latest model follows turns" latest_model_follows_turns;
      test "replay usage tracks latest response"
        replay_usage_tracks_latest_response;
      test "replay usage cleared by compaction"
        replay_usage_cleared_by_compaction;
      test "compaction preserves active turn" compaction_preserves_active_turn;
      test "compaction requires ready current transcript"
        compaction_requires_ready_current_transcript;
      test "compaction requires ready replacement transcript"
        compaction_requires_ready_replacement_transcript;
      test "final text projects latest assistant"
        final_text_projects_latest_assistant;
      test "compaction metadata round trips" compaction_metadata_round_trips;
      test "compaction rejects invalid metadata"
        compaction_rejects_invalid_metadata;
      test "clean finish rejects pending tool calls"
        clean_finish_rejects_pending_tool_calls;
      test "tool results require active turn" tool_results_require_active_turn;
      test "response model must match turn" response_model_must_match_turn;
      test "permission replies update grants" permission_replies_update_grants;
      test "permission request requires pending tool call"
        permission_request_requires_pending_tool_call;
      test "permission requests are serial" permission_requests_are_serial;
      test "raw tool result cannot bypass permission"
        raw_tool_result_cannot_bypass_permission;
      test "permission request JSON requires tool call"
        permission_request_json_requires_tool_call;
      test "terminal turns reject unresolved waiting"
        terminal_turns_reject_unresolved_waiting;
      test "session document appends and tracks state"
        session_document_appends_and_tracks_state;
      test "append paths preserve event order"
        append_paths_preserve_event_order;
      test "replay errors locate invalid events"
        replay_errors_locate_invalid_events;
      test "permission denial result must match blocked call"
        permission_denial_result_must_match_blocked_call;
      test "permission decision eliminator" permission_decision_eliminator;
      test "allow-once leaves session grants untouched"
        allow_once_leaves_session_grants_untouched;
      test "allow-session respects non-grantable requests"
        allow_session_respects_non_grantable_requests;
      test "tool claim blocks until finished" tool_claim_blocks_until_finished;
      test "raw tool result cannot bypass claim"
        raw_tool_result_cannot_bypass_claim;
      test "tool claim result must match started call"
        tool_claim_result_must_match_started_call;
      test "finished tool claim JSON requires output"
        finished_tool_claim_json_requires_output;
      test "archived and deleted sessions reject appends"
        archived_and_deleted_sessions_reject_appends;
      test "delete is idempotent for active tombstones"
        delete_is_idempotent_for_active_tombstone;
      test "archive rejects active turn" archive_rejects_active_turn;
      test "fork records parent lineage" fork_records_parent_lineage;
      test "fork rejects active turn" fork_rejects_active_turn;
      test "anchor names turn and edge" anchor_names_turn_and_edge;
      test "resolve anchor cuts at boundaries" resolve_anchor_cuts_at_boundaries;
      test "first turn prefix keeps idle events"
        first_turn_prefix_keeps_idle_events;
      test "resolve anchor error taxonomy" resolve_anchor_error_taxonomy;
      test "dropped turns is edge uniform" dropped_turns_is_edge_uniform;
      test "rewind past compaction uncompacts" rewind_past_compaction_uncompacts;
      test "rewind records prefix lineage" rewind_records_prefix_lineage;
      test "rewind at last boundary equals fork"
        rewind_at_last_boundary_equals_fork;
      test "rewind refuses active and unknown" rewind_refuses_active_and_unknown;
    ]
