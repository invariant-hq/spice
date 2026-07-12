(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Session = Spice_session
module Run = Spice_session_run
module Llm = Spice_llm
module Tool = Spice_tool
module Permission = Spice_permission
module Json = Jsont.Json

let model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"gpt-5"

let cwd = Spice_path.Abs.of_string_exn "/workspace"

let review_tool_declaration =
  Llm.Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
    ~input_schema:(Json.object' []) ()

let turn =
  Session.Turn.make
    ~id:(Session.Turn.Id.of_string "turn-1")
    ~input:(Session.Turn.Input.user_text "Use the tool.")
    ~model ~declarations:[ review_tool_declaration ] ~host_tools:[]
    ~max_steps:max_int ()

let empty_session () =
  Session.create
    ~id:(Session.Id.of_string "session-1")
    ~cwd
    ~created_at:(Session.Time.of_unix_ms 1L)
    ()

let session () =
  match
    Session.Log.append (Session.Event.turn_started turn) (empty_session ())
  with
  | Ok session -> session
  | Error error -> failf "turn start failed: %a" Session.Error.pp error

let session_with turn =
  match
    Session.Log.append (Session.Event.turn_started turn) (empty_session ())
  with
  | Ok session -> session
  | Error error -> failf "turn start failed: %a" Session.Error.pp error

let with_status status session =
  let metadata =
    Session.Metadata.with_status status (Session.metadata session)
  in
  match
    Session.make ~id:(Session.id session) ~metadata
      ~events:(Session.events session)
  with
  | Ok session -> session
  | Error error -> failf "status fixture failed: %a" Session.Error.pp error

let call ?(id = "call-1") ?(name = "review_tool") () =
  Llm.Tool.Call.make ~id ~name ~input:(Json.object' []) ()

let response call =
  Llm.Response.make ~model
    (Llm.Message.Assistant.make [ Llm.Message.Assistant.tool_call call ])

let output () = Tool.Output.make ~text:"ok" ()

let executable_tool ?(subject = "alpha") () =
  let permissions () =
    [
      Permission.Request.of_accesses
        [ Permission.Access.custom ~subject "review_tool" ];
    ]
  in
  Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
    ~input:Tool.Input.empty ~output ~permissions
    ~run:(fun _context () -> Tool.Result.completed ~output:() ())
    ()

let repeated_access_tool () =
  let access =
    Permission.Access.custom ~subject:"same" "review_tool"
  in
  let permissions () =
    [
      Permission.Request.of_accesses ~source:"first" [ access ];
      Permission.Request.make ~source:"second"
        [
          Permission.Request.Item.make
            ~change:
              (Permission.Request.Change.make ~diff:"+line" ~additions:1 ())
            access;
        ];
    ]
  in
  Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
    ~input:Tool.Input.empty ~output ~permissions
    ~run:(fun _context () -> Tool.Result.completed ~output:() ())
    ()

let raising_permissions_tool () =
  let permissions () = invalid_arg "permission planner bug" in
  Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
    ~input:Tool.Input.empty ~output ~permissions
    ~run:(fun _context () -> Tool.Result.completed ~output:() ())
    ()

let config ?(policy = Permission.Policy.default) ?host_tools ?on_review ?prelude
    ?max_steps tools =
  Run.Config.make ~tools ?host_tools ~policy:(fun _ -> policy) ?on_review
    ?prelude ?safety_step_cap:max_steps ()

let config_construction_is_programmer_local () =
  expect_invalid_arg "non-positive safety cap raises" (fun () ->
      Run.Config.make ~tools:[]
        ~policy:(fun _ -> Permission.Policy.default)
        ~safety_step_cap:0 ());
  expect_invalid_arg "duplicate tool names raise" (fun () ->
      Run.Config.make
        ~tools:[ executable_tool (); executable_tool () ]
        ~policy:(fun _ -> Permission.Policy.default) ());
  let bad_name_tool =
    Tool.make ~name:"bad name" ~description:"Bad tool name."
      ~input:Tool.Input.empty ~output
      ~run:(fun _context () -> Tool.Result.completed ~output:() ())
      ()
  in
  expect_invalid_arg "invalid executable tool names raise" (fun () ->
      Run.Config.make ~tools:[ bad_name_tool ]
        ~policy:(fun _ -> Permission.Policy.default) ());
  let host_tool name = Llm.Tool.make ~name ~input_schema:(Json.object' []) () in
  expect_invalid_arg "executable and host tool name collisions raise" (fun () ->
      Run.Config.make
        ~tools:[ executable_tool () ]
        ~host_tools:[ host_tool "review_tool" ]
        ~policy:(fun _ -> Permission.Policy.default) ());
  expect_invalid_arg "duplicate host tool names raise" (fun () ->
      Run.Config.make ~tools:[]
        ~host_tools:[ host_tool "ask_user"; host_tool "ask_user" ]
        ~policy:(fun _ -> Permission.Policy.default) ())

let permission_from_step step =
  match Run.Step.next step with
  | Run.Step.Waiting (Session.Waiting.Permission request) -> request
  | next -> failf "expected permission block, got %a" Run.Step.pp_next next

let run_response config response =
  match Run.accept_response config response (session ()) with
  | Ok step -> step
  | Error error -> failf "record response failed: %a" Run.Error.pp error

let review_bypass_runs_without_a_permission_boundary () =
  let config =
    config ~on_review:Permission.Policy.Allow [ executable_tool () ]
  in
  match Run.Step.next (run_response config (response (call ()))) with
  | Run.Step.Run_tool _ -> ()
  | next -> failf "expected bypassed tool run, got %a" Run.Step.pp_next next

let deterministic_permission_ids () =
  let call = call () in
  let response = response call in
  let first =
    run_response (config [ executable_tool ~subject:"alpha" () ]) response
    |> permission_from_step
  in
  let second =
    run_response (config [ executable_tool ~subject:"alpha" () ]) response
    |> permission_from_step
  in
  equal
    (testable ~pp:Session.Permission.Id.pp ~equal:Session.Permission.Id.equal ())
    ~msg:"same reviewed access gives same permission id"
    (Session.Permission.Requested.id first)
    (Session.Permission.Requested.id second);
  let changed =
    run_response (config [ executable_tool ~subject:"beta" () ]) response
    |> permission_from_step
  in
  is_false ~msg:"different reviewed access changes permission id"
    (Session.Permission.Id.equal
       (Session.Permission.Requested.id first)
       (Session.Permission.Requested.id changed))

let permission_ids_include_request_position () =
  let config = config [ repeated_access_tool () ] in
  let blocked = run_response config (response (call ())) in
  let first = permission_from_step blocked in
  match
    Run.resolve_permission config
      (Session.Permission.Requested.id first)
      (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
      (Run.Step.session blocked)
  with
  | Error error -> failf "first allow failed: %a" Run.Error.pp error
  | Ok step ->
      let second = permission_from_step step in
      is_false
        ~msg:"metadata-distinct requests with the same access get distinct ids"
        (Session.Permission.Id.equal
           (Session.Permission.Requested.id first)
           (Session.Permission.Requested.id second))

let permission_ids_include_full_request () =
  let access =
    Permission.Access.custom ~subject:"same" "review_tool"
  in
  let ids_after_change first_request second_request =
    let request = ref first_request in
    let permissions () =
      [ !request ]
    in
    let tool =
      Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
        ~input:Tool.Input.empty ~output ~permissions
        ~run:(fun _context () -> Tool.Result.completed ~output:() ())
        ()
    in
    let config = config [ tool ] in
    let blocked = run_response config (response (call ())) in
    let first = permission_from_step blocked in
    request := second_request;
    match
      Run.resolve_permission config
        (Session.Permission.Requested.id first)
        (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
        (Run.Step.session blocked)
    with
    | Error error ->
        failf "changed request could not re-review: %a" Run.Error.pp error
    | Ok step -> (
        match Run.Step.next step with
        | Run.Step.Waiting (Session.Waiting.Permission second) ->
            ( Session.Permission.Requested.id first,
              Session.Permission.Requested.id second )
        | next ->
            failf "expected changed permission review, got %a"
              Run.Step.pp_next next)
  in
  let display text =
    Permission.Request.make
      [ Permission.Request.Item.make ~display:text access ]
  in
  let change diff =
    Permission.Request.make
      [
        Permission.Request.Item.make
          ~change:(Permission.Request.Change.make ~diff ())
          access;
      ]
  in
  let cases =
    [
      ( "source",
        Permission.Request.of_accesses ~source:"first" [ access ],
        Permission.Request.of_accesses ~source:"changed" [ access ] );
      ("display", display "first", display "changed");
      ("change", change "+first", change "+changed");
    ]
  in
  List.iter
    (fun (field, first_request, second_request) ->
      let first, second = ids_after_change first_request second_request in
      is_false ~msg:(field ^ " changes the permission attempt id")
        (Session.Permission.Id.equal first second))
    cases

let permission_planner_exceptions_become_tool_errors () =
  let step =
    run_response (config [ raising_permissions_tool () ]) (response (call ()))
  in
  (match Run.Step.next step with
  | Run.Step.Request_model _ -> ()
  | next ->
      failf "expected model request after permission error, got %a"
        Run.Step.pp_next next);
  let state = Session.state (Run.Step.session step) in
  is_true ~msg:"permission error answers the pending tool call"
    (Llm.Transcript.is_ready (Session.State.transcript state));
  match List.rev (Run.Step.events step) with
  | Session.Event.Message_appended (Llm.Message.Tool_result result) :: _ ->
      is_true ~msg:"permission error is model-visible"
        (Llm.Tool.Result.is_error result);
      check "permission error names the planner failure"
        (List.exists
           (String.includes ~affix:"permission planner bug")
           (Llm.Tool.Result.texts result))
  | _ -> failf "expected a durable tool error event"

let preflight_from_step step =
  match Run.Step.next step with
  | Run.Step.Prepare_tool preflight -> preflight
  | next -> failf "expected tool preflight, got %a" Run.Step.pp_next next

let staged_preflight_waits_for_preliminary_permission () =
  let prepared = ref 0 in
  let preliminary = Permission.Access.custom "preflight.read" in
  let tool =
    Tool.make_staged ~name:"review_tool" ~description:"Staged test tool."
      ~input:Tool.Input.empty ~output
      ~preliminary_permissions:(fun () ->
        [ Permission.Request.of_accesses [ preliminary ] ])
      ~prepare:(fun _context () ->
        incr prepared;
        `Prepared ())
      ~permissions:(fun () ->
        [
          Permission.Request.of_accesses
            [ Permission.Access.custom "preflight.write" ];
        ])
      ~run:(fun _context () -> Tool.Result.completed ~output:() ())
      ()
  in
  let step = run_response (config [ tool ]) (response (call ())) in
  ignore (permission_from_step step : Session.Permission.Requested.t);
  equal int ~msg:"preflight did not start before preliminary consent" 0
    !prepared

let staged_preflight_checks_final_facts_before_claiming () =
  let prepared = ref 0 in
  let ran = ref 0 in
  let preliminary = Permission.Access.custom "preflight.read" in
  let final = Permission.Access.custom "preflight.write" in
  let tool =
    Tool.make_staged ~name:"review_tool" ~description:"Staged test tool."
      ~input:Tool.Input.empty ~output
      ~preliminary_permissions:(fun () ->
        [ Permission.Request.of_accesses [ preliminary ] ])
      ~prepare:(fun _context () ->
        incr prepared;
        `Prepared ())
      ~permissions:(fun () ->
        [ Permission.Request.of_accesses [ final ] ])
      ~run:(fun _context () ->
        incr ran;
        Tool.Result.completed ~output:() ())
      ()
  in
  let policy =
    Permission.Policy.make
      [ Permission.Policy.Rule.allow (Permission.Policy.Match.exact preliminary) ]
  in
  let config = config ~policy [ tool ] in
  let first = run_response config (response (call ())) in
  let preflight = preflight_from_step first in
  let preparation = Run.Preflight.prepare preflight in
  equal int ~msg:"preflight ran once" 1 !prepared;
  let blocked =
    match
      Run.finish_tool_preflight config preflight preparation
        (Run.Step.session first)
    with
    | Ok step -> step
    | Error error -> failf "preflight completion failed: %a" Run.Error.pp error
  in
  let requested = permission_from_step blocked in
  equal int ~msg:"mutation did not run before final consent" 0 !ran;
  let resumed =
    match
      Run.resolve_permission config
        (Session.Permission.Requested.id requested)
        (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
        (Run.Step.session blocked)
    with
    | Ok step -> step
    | Error error -> failf "final permission allow failed: %a" Run.Error.pp error
  in
  let preflight = preflight_from_step resumed in
  let preparation = Run.Preflight.prepare preflight in
  let claimed =
    match
      Run.finish_tool_preflight config preflight preparation
        (Run.Step.session resumed)
    with
    | Ok step -> step
    | Error error -> failf "allowed preflight failed: %a" Run.Error.pp error
  in
  equal int ~msg:"repeatable preflight reran after consent" 2 !prepared;
  equal int ~msg:"mutation still waits for the durable claim" 0 !ran;
  match Run.Step.next claimed with
  | Run.Step.Run_tool { execution; _ } ->
      ignore (Tool.Execution.run execution () : Tool.Output.t Tool.Result.t);
      equal int ~msg:"claimed prepared mutation ran once" 1 !ran
  | next -> failf "expected prepared tool claim, got %a" Run.Step.pp_next next

let tool_claim_from_step step =
  match Run.Step.next step with
  | Run.Step.Run_tool { claim; execution = _ } -> claim
  | next -> failf "expected tool claim, got %a" Run.Step.pp_next next

let deterministic_tool_claim_ids () =
  let tool = executable_tool () in
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let config = config ~policy [ tool ] in
  let first =
    run_response config (response (call ~id:"call-1" ()))
    |> tool_claim_from_step
  in
  let second =
    run_response config (response (call ~id:"call-1" ()))
    |> tool_claim_from_step
  in
  equal
    (testable ~pp:Session.Tool_claim.Id.pp ~equal:Session.Tool_claim.Id.equal ())
    ~msg:"same tool call gives same execution id"
    (Session.Tool_claim.Started.id first)
    (Session.Tool_claim.Started.id second);
  let changed =
    run_response config (response (call ~id:"call-2" ()))
    |> tool_claim_from_step
  in
  is_false ~msg:"different tool call changes execution id"
    (Session.Tool_claim.Id.equal
       (Session.Tool_claim.Started.id first)
       (Session.Tool_claim.Started.id changed))

let finish_tool_uses_saved_claim_id () =
  let tool = executable_tool () in
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let config = config ~policy [ tool ] in
  let claimed = run_response config (response (call ())) in
  let saved = tool_claim_from_step claimed in
  match
    Run.finish_tool config (Session.Tool_claim.Started.id saved)
      (Tool.Result.completed ~output:(output ()) ())
      (Run.Step.session claimed)
  with
  | Error error -> failf "finish failed: %a" Run.Error.pp error
  | Ok step ->
      let state = Session.state (Run.Step.session step) in
      (match Session.State.tool_claims state with
      | [ (started, Some _) ] ->
          is_true ~msg:"finish resolves the saved claim"
            (Session.Tool_claim.Started.equal saved started)
      | _ -> failf "expected one finished saved claim")

let conversation_family_affects_later_call_in_same_turn () =
  let tool = executable_tool () in
  let config =
    Run.Config.make ~tools:[ tool ]
      ~policy:(fun rules -> Permission.Policy.make rules) ()
  in
  let calls = [ call ~id:"call-1" (); call ~id:"call-2" () ] in
  let response =
    Llm.Response.make ~model
      (Llm.Message.Assistant.make
         (List.map Llm.Message.Assistant.tool_call calls))
  in
  let blocked = run_response config response in
  let requested = permission_from_step blocked in
  let rule =
    Permission.Policy.Rule.allow
      (Permission.Policy.Match.custom ~subject:"alpha" "review_tool")
  in
  let first =
    match
      Run.resolve_permission config
        (Session.Permission.Requested.id requested)
        (Session.Permission.Resolved.Allow
           (Session.Permission.Resolved.Family
              {
                lifetime = Session.Permission.Resolved.Conversation;
                rules = [ rule ];
              }))
        (Run.Step.session blocked)
    with
    | Ok step -> step
    | Error error -> failf "family allow failed: %a" Run.Error.pp error
  in
  let first_claim = tool_claim_from_step first in
  match
    Run.finish_tool config (Session.Tool_claim.Started.id first_claim)
      (Tool.Result.completed ~output:(output ()) ())
      (Run.Step.session first)
  with
  | Error error -> failf "first tool finish failed: %a" Run.Error.pp error
  | Ok second ->
      let second_claim = tool_claim_from_step second in
      equal string ~msg:"conversation rule allows the later matching call"
        "call-2"
        (Llm.Tool.Call.id (Session.Tool_claim.Started.call second_claim))

let accepted_step_limit_cannot_be_widened () =
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let tool = executable_tool () in
  let accepted = config ~policy ~max_steps:1 [ tool ] in
  let resumed = config ~policy ~max_steps:100 [ tool ] in
  let turn_id = Session.Turn.Id.of_string "turn-limit" in
  let started =
    match
      Run.start accepted ~id:turn_id
        ~input:(Session.Turn.Input.user_text "Use the tool.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  let count message session expected =
    equal (option int) ~msg:message (Some expected)
      (Session.State.turn_response_count turn_id (Session.state session))
  in
  count "new turn starts at zero responses" (Run.Step.session started) 0;
  let claimed =
    match
      Run.accept_response accepted (response (call ()))
        (Run.Step.session started)
    with
    | Ok step -> step
    | Error error -> failf "response failed: %a" Run.Error.pp error
  in
  count "accepted response increments the durable count"
    (Run.Step.session claimed) 1;
  let claim = tool_claim_from_step claimed in
  match
    Run.finish_tool resumed (Session.Tool_claim.Started.id claim)
      (Tool.Result.completed ~output:(output ()) ())
      (Run.Step.session claimed)
  with
  | Error error -> failf "finish failed: %a" Run.Error.pp error
  | Ok step -> (
      let terminal_events =
        List.filter
          (function Session.Event.Turn_finished _ -> true | _ -> false)
          (Run.Step.events step)
      in
      equal int ~msg:"step-limit finish appends one terminal event" 1
        (List.length terminal_events);
      match Run.Step.next step with
      | Run.Step.Finished { outcome = Session.Turn.Outcome.Step_limit; _ } -> ()
      | next ->
          failf "looser resume widened the accepted limit: %a"
            Run.Step.pp_next next)

let accepted_step_limit_is_resolved_and_clamped () =
  let check ?max_steps safety_step_cap expected =
    let config = config ~max_steps:safety_step_cap [] in
    let id = Session.Turn.Id.of_string "turn-limit" in
    let started =
      match
        Run.start config ~id
          ~input:(Session.Turn.Input.user_text "Continue.") ~model ?max_steps
          (empty_session ())
      with
      | Ok step -> Run.Step.session step
      | Error error -> failf "start failed: %a" Run.Error.pp error
    in
    match Session.State.turn id (Session.state started) with
    | None -> failf "accepted turn is missing"
    | Some turn ->
        equal int ~msg:"effective limit is durable" expected
          (Session.Turn.max_steps turn)
  in
  check 3 3;
  check ~max_steps:1 3 1;
  check ~max_steps:10 3 3

let current_step_cap_can_tighten () =
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let tool = executable_tool () in
  let accepted = config ~policy ~max_steps:100 [ tool ] in
  let tightened = config ~policy ~max_steps:1 [ tool ] in
  let started =
    match
      Run.start accepted ~id:(Session.Turn.Id.of_string "turn-limit")
        ~input:(Session.Turn.Input.user_text "Use the tool.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  let claimed =
    match
      Run.accept_response accepted (response (call ()))
        (Run.Step.session started)
    with
    | Ok step -> step
    | Error error -> failf "response failed: %a" Run.Error.pp error
  in
  let claim = tool_claim_from_step claimed in
  match
    Run.finish_tool tightened (Session.Tool_claim.Started.id claim)
      (Tool.Result.completed ~output:(output ()) ())
      (Run.Step.session claimed)
  with
  | Error error -> failf "finish failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Finished { outcome = Session.Turn.Outcome.Step_limit; _ } -> ()
      | next ->
          failf "current safety cap did not tighten the turn: %a"
            Run.Step.pp_next next)

let block_turn_string block =
  Session.Turn.Id.to_string (Session.Waiting.turn block)

let block_accessors_identify_call_and_turn () =
  let permission_block =
    Session.Waiting.Permission
      (run_response (config [ executable_tool () ]) (response (call ()))
      |> permission_from_step)
  in
  equal string ~msg:"permission block identifies its call" "call-1"
    (Llm.Tool.Call.id (Session.Waiting.call permission_block));
  equal string ~msg:"permission block records its turn" "turn-1"
    (block_turn_string permission_block);
  let host_tool_block =
    Session.Waiting.host_tool ~turn:(Session.Turn.id turn)
      (call ~id:"question-1" ~name:"ask_user" ())
  in
  equal string ~msg:"host-tool block identifies its call" "question-1"
    (Llm.Tool.Call.id (Session.Waiting.call host_tool_block));
  equal string ~msg:"host-tool payload records turn" "turn-1"
    (block_turn_string host_tool_block);
  let execution_block =
    let policy =
      Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
    in
    Session.Waiting.Tool_claim
      (run_response (config ~policy [ executable_tool () ]) (response (call ()))
      |> tool_claim_from_step)
  in
  equal string ~msg:"execution block identifies its call" "call-1"
    (Llm.Tool.Call.id (Session.Waiting.call execution_block));
  equal string ~msg:"execution block records its turn" "turn-1"
    (block_turn_string execution_block)

let interrupt_finishes_turn_as_cancelled () =
  let step =
    match Run.interrupt ~reason:"user interrupt" (session ()) with
    | Ok step -> step
    | Error error -> failf "interrupt failed: %a" Run.Error.pp error
  in
  equal int ~msg:"interrupt appends one terminal event" 1
    (List.length (Run.Step.events step));
  (match Run.Step.next step with
  | Run.Step.Finished { turn = turn_id; outcome } -> (
      is_true ~msg:"interrupt finishes the active turn"
        (Session.Turn.Id.equal turn_id (Session.Turn.id turn));
      match outcome with
      | Session.Turn.Outcome.Interrupted { reason; cancelled } ->
          is_true ~msg:"interrupt records cancellation" cancelled;
          equal (option string) ~msg:"interrupt records the reason"
            (Some "user interrupt") reason
      | _ ->
          failf "expected interrupted outcome, got %a" Run.Step.pp_next
            (Run.Step.next step))
  | next -> failf "expected finished step, got %a" Run.Step.pp_next next);
  equal
    (option (testable ~pp:Session.Turn.Id.pp ~equal:Session.Turn.Id.equal ()))
    ~msg:"interrupted session has no active turn" None
    (Session.State.active_turn_id (Session.state (Run.Step.session step)));
  match Run.interrupt (empty_session ()) with
  | Ok _ -> failf "interrupt without active turn should fail"
  | Error Run.Error.No_active_turn -> ()
  | Error error -> failf "unexpected interrupt error: %a" Run.Error.pp error

(* The drive's repair: a turn whose model call failed terminally must still
   reach a terminal event, or it stays active in the saved session and every
   later command is refused against it. *)
let fail_finishes_turn_as_failed () =
  let step =
    match Run.fail ~message:"openai rate-limited the request" (session ()) with
    | Ok step -> step
    | Error error -> failf "fail failed: %a" Run.Error.pp error
  in
  equal int ~msg:"fail appends one terminal event" 1
    (List.length (Run.Step.events step));
  (match Run.Step.next step with
  | Run.Step.Finished { turn = turn_id; outcome } -> (
      is_true ~msg:"fail finishes the active turn"
        (Session.Turn.Id.equal turn_id (Session.Turn.id turn));
      match outcome with
      | Session.Turn.Outcome.Failed { message } ->
          equal string ~msg:"fail records the message"
            "openai rate-limited the request" message
      | _ ->
          failf "expected failed outcome, got %a" Run.Step.pp_next
            (Run.Step.next step))
  | next -> failf "expected finished step, got %a" Run.Step.pp_next next);
  equal
    (option (testable ~pp:Session.Turn.Id.pp ~equal:Session.Turn.Id.equal ()))
    ~msg:"failed session has no active turn" None
    (Session.State.active_turn_id (Session.state (Run.Step.session step)));
  match Run.fail ~message:"nothing to close" (empty_session ()) with
  | Ok _ -> failf "fail without active turn should fail"
  | Error Run.Error.No_active_turn -> ()
  | Error error -> failf "unexpected fail error: %a" Run.Error.pp error

let prelude_reaches_model_request () =
  let prelude =
    match Llm.Request.Prelude.make [ Llm.Message.system "Be brief." ] with
    | Ok prelude -> prelude
    | Error error -> failf "prelude failed: %a" Llm.Request.Error.pp error
  in
  let config = config ~prelude [] in
  match Run.resume config (session ()) with
  | Error error -> failf "resume failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Request_model request -> (
          match Llm.Request.Prelude.messages (Llm.Request.prelude request) with
          | [ Llm.Message.System text ] ->
              equal string ~msg:"config prelude reaches the built request"
                "Be brief." text
          | _ -> failf "unexpected prelude messages in request")
      | next -> failf "expected model request, got %a" Run.Step.pp_next next)

let resumed_turn_keeps_accepted_tool_declarations () =
  let host_tool description =
    Llm.Tool.make ~name:"ask_user" ~description
      ~input_schema:(Json.object' []) ()
  in
  let started =
    match
      Run.start
        (config ~host_tools:[ host_tool "accepted" ] [])
        ~id:(Session.Turn.Id.of_string "turn-1")
        ~input:(Session.Turn.Input.user_text "Ask me.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  let saved =
    decode Session.jsont (encode Session.jsont (Run.Step.session started))
  in
  match
    Run.resume
      (config ~host_tools:[ host_tool "replacement" ] [])
      saved
  with
  | Error error -> failf "resume failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Request_model request -> (
          match Llm.Request.tools request with
          | [ declaration ] ->
              equal (option string) ~msg:"accepted declaration is durable"
                (Some "accepted")
                (Llm.Tool.description declaration)
          | declarations ->
              failf "expected one declaration, got %d"
                (List.length declarations))
      | next -> failf "expected model request, got %a" Run.Step.pp_next next)

let resumed_turn_rejects_new_executable_tool () =
  let started =
    match
      Run.start (config []) ~id:(Session.Turn.Id.of_string "turn-1")
        ~input:(Session.Turn.Input.user_text "Continue.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  match
    Run.accept_response
      (config [ executable_tool () ])
      (response (call ())) (Run.Step.session started)
  with
  | Error error -> failf "response failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Request_model _ ->
          let transcript =
            Session.State.transcript (Session.state (Run.Step.session step))
          in
          is_true ~msg:"undeclared call receives a model-visible error"
            (Llm.Transcript.is_ready transcript)
      | next ->
          failf "new executable escaped the accepted contract: %a"
            Run.Step.pp_next next)

let automatic_rejections_preserve_order () =
  let call_count = 1_000 in
  let calls =
    List.init call_count (fun index ->
        call ~id:("call-" ^ string_of_int index) ~name:"missing_tool" ())
  in
  let assistant =
    List.map Llm.Message.Assistant.tool_call calls
    |> Llm.Message.Assistant.make
  in
  let response = Llm.Response.make ~model assistant in
  let config = config [] in
  let started =
    match
      Run.start config ~id:(Session.Turn.Id.of_string "turn-rejections")
        ~input:(Session.Turn.Input.user_text "Continue.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  match Run.accept_response config response (Run.Step.session started) with
  | Error error -> failf "response failed: %a" Run.Error.pp error
  | Ok step -> (
      (match Run.Step.next step with
      | Run.Step.Request_model _ -> ()
      | next ->
          failf "automatic rejection did not reach the model: %a"
            Run.Step.pp_next next);
      match Run.Step.events step with
      | Session.Event.Response_appended _ :: result_events ->
          equal int ~msg:"one result is emitted per rejected call" call_count
            (List.length result_events);
          List.iter2
            (fun expected event ->
              match event with
              | Session.Event.Message_appended (Llm.Message.Tool_result result)
                ->
                  equal string ~msg:"rejection results preserve provider order"
                    (Llm.Tool.Call.id expected)
                    (Llm.Tool.Result.call_id result);
                  equal string ~msg:"rejection result keeps the tool name"
                    (Llm.Tool.Call.name expected)
                    (Llm.Tool.Result.name result);
                  is_true ~msg:"automatic rejection is a tool error"
                    (Llm.Tool.Result.is_error result)
              | _ -> failf "expected a tool-result event")
            calls result_events
      | _ -> failf "expected the response before rejection results")

let mixed_call_interrupt_preserves_boundaries () =
  let host_tool =
    Llm.Tool.make ~name:"ask_user" ~input_schema:(Json.object' []) ()
  in
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let config =
    config ~policy ~host_tools:[ host_tool ] [ executable_tool () ]
  in
  let started =
    match
      Run.start config ~id:(Session.Turn.Id.of_string "turn-mixed")
        ~input:(Session.Turn.Input.user_text "Handle the calls.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  let missing = call ~id:"call-missing" ~name:"missing_tool" () in
  let executable = call ~id:"call-executable" () in
  let host = call ~id:"call-host" ~name:"ask_user" () in
  let response =
    Llm.Response.make ~model
      (Llm.Message.Assistant.make
         (List.map Llm.Message.Assistant.tool_call
            [ missing; executable; host ]))
  in
  let claimed =
    match Run.accept_response config response (Run.Step.session started) with
    | Ok step -> step
    | Error error -> failf "response failed: %a" Run.Error.pp error
  in
  let claim = tool_claim_from_step claimed in
  (match Run.Step.events claimed with
  | [
   Session.Event.Response_appended _;
   Session.Event.Message_appended (Llm.Message.Tool_result rejected);
   Session.Event.Tool_claim_started started_claim;
  ] ->
      equal string ~msg:"automatic rejection is first" "call-missing"
        (Llm.Tool.Result.call_id rejected);
      is_true ~msg:"step returns the persisted executable claim"
        (Session.Tool_claim.Started.equal claim started_claim)
  | _ -> failf "unexpected mixed-call normalization events");
  match Run.interrupt ~reason:"cancelled" (Run.Step.session claimed) with
  | Error error -> failf "interrupt failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.events step with
      | [
       Session.Event.Tool_claim_finished finished;
       Session.Event.Message_appended (Llm.Message.Tool_result host_result);
       Session.Event.Turn_finished _;
      ] ->
          equal string ~msg:"claimed call is finished first" "call-executable"
            (Llm.Tool.Result.call_id
               (Session.Tool_claim.Finished.result finished));
          equal string ~msg:"unclaimed host call is answered second" "call-host"
            (Llm.Tool.Result.call_id host_result)
      | _ -> failf "unexpected mixed-call interrupt events")

let mixed_call_drains_to_host_boundary () =
  let host_tool =
    Llm.Tool.make ~name:"ask_user" ~input_schema:(Json.object' []) ()
  in
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let config =
    config ~policy ~host_tools:[ host_tool ] [ executable_tool () ]
  in
  let started =
    match
      Run.start config ~id:(Session.Turn.Id.of_string "turn-mixed-drain")
        ~input:(Session.Turn.Input.user_text "Handle both calls.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  let executable = call ~id:"call-executable" () in
  let host = call ~id:"call-host" ~name:"ask_user" () in
  let response =
    Llm.Response.make ~model
      (Llm.Message.Assistant.make
         (List.map Llm.Message.Assistant.tool_call [ executable; host ]))
  in
  let claimed =
    match Run.accept_response config response (Run.Step.session started) with
    | Ok step -> step
    | Error error -> failf "response failed: %a" Run.Error.pp error
  in
  let claim = tool_claim_from_step claimed in
  let host_waiting, after_tool =
    match
      Run.finish_tool config (Session.Tool_claim.Started.id claim)
        (Tool.Result.completed ~output:(output ()) ())
        (Run.Step.session claimed)
    with
    | Error error -> failf "finish failed: %a" Run.Error.pp error
    | Ok step -> (
        (match
           Session.State.tool_claims (Session.state (Run.Step.session step))
         with
        | [ (started, Some _) ] ->
            is_true ~msg:"first claim is durably finished"
              (Session.Tool_claim.Started.equal claim started)
        | _ -> failf "expected one finished claim");
        match Run.Step.next step with
        | Run.Step.Waiting (Session.Waiting.Host_tool waiting) -> (waiting, step)
        | next ->
            failf "expected second host boundary, got %a" Run.Step.pp_next next)
  in
  match
    Run.answer_host_tool config host_waiting ~text:"staging"
      (Run.Step.session after_tool)
  with
  | Error error -> failf "host answer failed: %a" Run.Error.pp error
  | Ok step ->
      (match Run.Step.next step with
      | Run.Step.Request_model _ -> ()
      | next -> failf "expected model request, got %a" Run.Step.pp_next next);
      let result_ids =
        Llm.Transcript.messages
          (Session.State.transcript (Session.state (Run.Step.session step)))
        |> List.filter_map (function
             | Llm.Message.Tool_result result ->
                 Some (Llm.Tool.Result.call_id result)
             | Llm.Message.System _ | Llm.Message.Developer _
             | Llm.Message.User _ | Llm.Message.Assistant _ ->
                 None)
      in
      equal (list string) ~msg:"tool results preserve provider order"
        [ "call-executable"; "call-host" ] result_ids

let accepted_host_tool_keeps_routing () =
  let declaration =
    Llm.Tool.make ~name:"review_tool" ~input_schema:(Json.object' []) ()
  in
  let started =
    match
      Run.start
        (config ~host_tools:[ declaration ] [])
        ~id:(Session.Turn.Id.of_string "turn-1")
        ~input:(Session.Turn.Input.user_text "Review this.") ~model
        (empty_session ())
    with
    | Ok step -> step
    | Error error -> failf "start failed: %a" Run.Error.pp error
  in
  match
    Run.accept_response
      (config [ executable_tool () ])
      (response (call ())) (Run.Step.session started)
  with
  | Error error -> failf "response failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Waiting (Session.Waiting.Host_tool _) -> ()
      | next ->
          failf "accepted host ownership changed on resume: %a"
            Run.Step.pp_next next)

let turn_tool_contract_is_checked () =
  let declaration =
    Llm.Tool.make ~name:"ask_user" ~input_schema:(Json.object' []) ()
  in
  let make ?(max_steps = max_int) declarations host_tools =
    Session.Turn.make ~id:(Session.Turn.Id.of_string "turn-contract")
      ~input:(Session.Turn.Input.user_text "Ask.") ~model ~declarations
      ~host_tools ~max_steps ()
  in
  expect_invalid_arg "duplicate declarations raise" (fun () ->
      make [ declaration; declaration ] []);
  expect_invalid_arg "duplicate host ownership raises" (fun () ->
      make [ declaration ] [ "ask_user"; "ask_user" ]);
  expect_invalid_arg "host ownership requires a declaration" (fun () ->
      make [] [ "ask_user" ]);
  expect_invalid_arg "turn limit must be positive" (fun () ->
      make ~max_steps:0 [] [])

let resume_requires_active_lifecycle () =
  let config = config [] in
  let check status expected =
    match Run.resume config (with_status status (session ())) with
    | Error Run.Error.Archived when expected = `Archived -> ()
    | Error Run.Error.Deleted when expected = `Deleted -> ()
    | Error error -> failf "unexpected lifecycle error: %a" Run.Error.pp error
    | Ok step ->
        failf "inactive session planned an external boundary: %a"
          Run.Step.pp_next (Run.Step.next step)
  in
  check Session.Metadata.Status.Archived `Archived;
  check Session.Metadata.Status.Deleted `Deleted

let resolve_permission_deny_answers_blocked_call () =
  let config = config [ executable_tool () ] in
  let blocked = run_response config (response (call ())) in
  let request = permission_from_step blocked in
  let blocked_session = Run.Step.session blocked in
  (match
     Run.resolve_permission config
       (Session.Permission.Requested.id request)
       Session.Permission.Resolved.Deny blocked_session
   with
  | Error error -> failf "deny failed: %a" Run.Error.pp error
  | Ok step -> (
      equal int ~msg:"denial appends one atomic durable event" 1
        (List.length (Run.Step.events step));
      let state = Session.state (Run.Step.session step) in
      equal int ~msg:"permission is no longer pending" 0
        (List.length (Session.State.pending_permissions state));
      is_true ~msg:"denial answers the pending tool call"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      match Run.Step.next step with
      | Run.Step.Request_model _ -> ()
      | next ->
          failf "expected model request after deny, got %a" Run.Step.pp_next
            next));
  let unknown = Session.Permission.Id.of_string "perm:unknown" in
  match
    Run.resolve_permission config unknown
      (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
      (session ())
  with
  | Ok _ -> failf "resolving an unknown permission should fail"
  | Error (Run.Error.Permission_not_pending id) ->
      is_true ~msg:"error carries the unknown permission id"
        (Session.Permission.Id.equal id unknown)
  | Error error -> failf "unexpected resolve error: %a" Run.Error.pp error

let answer_tool_records_tool_result () =
  let host_tool =
    Llm.Tool.make ~name:"ask_user" ~input_schema:(Json.object' []) ()
  in
  let turn =
    Session.Turn.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~input:(Session.Turn.Input.user_text "Use the host tool.")
      ~model ~declarations:[ host_tool ] ~host_tools:[ "ask_user" ]
      ~max_steps:max_int ()
  in
  let config = config ~host_tools:[ host_tool ] [] in
  let blocked =
    match
      Run.accept_response config
        (response (call ~id:"question-1" ~name:"ask_user" ()))
        (session_with turn)
    with
    | Ok step -> step
    | Error error -> failf "record response failed: %a" Run.Error.pp error
  in
  (match Run.Step.next blocked with
  | Run.Step.Waiting (Session.Waiting.Host_tool _) -> ()
  | next -> failf "expected host tool block, got %a" Run.Step.pp_next next);
  let session = Run.Step.session blocked in
  (match
     let waiting =
       match Run.Step.next blocked with
       | Run.Step.Waiting (Session.Waiting.Host_tool waiting) -> waiting
       | next -> failf "expected host tool block, got %a" Run.Step.pp_next next
     in
     Run.answer_host_tool config waiting ~text:"Use the staging branch." session
   with
  | Error error -> failf "answer failed: %a" Run.Error.pp error
  | Ok step ->
      equal int ~msg:"answer appends one durable tool-result event" 1
        (List.length (Run.Step.events step));
      is_true ~msg:"answer consumes the pending call"
        (Llm.Transcript.is_ready
           (Session.State.transcript (Session.state (Run.Step.session step)))));
  match
    let waiting =
      Session.Waiting.host_tool ~turn:(Session.Turn.id turn)
        (call ~id:"question-1" ~name:"other_tool" ())
    in
    match waiting with
    | Session.Waiting.Host_tool waiting ->
        Run.answer_host_tool config waiting ~text:"No." session
    | _ -> assert false
  with
  | Ok _ -> failf "answering with a wrong tool name should fail"
  | Error (Run.Error.Tool_call_not_pending { call_id; name }) ->
      equal string ~msg:"error carries the call id" "question-1" call_id;
      equal string ~msg:"error carries the requested name" "other_tool" name
  | Error error -> failf "unexpected answer error: %a" Run.Error.pp error

let host_tool_answer_rejects_executable_call () =
  let config = config [ executable_tool () ] in
  let tool_call = call ~id:"call-1" ~name:"review_tool" () in
  let blocked = run_response config (response tool_call) in
  (match Run.Step.next blocked with
  | Run.Step.Waiting (Session.Waiting.Permission _) -> ()
  | next -> failf "expected permission block, got %a" Run.Step.pp_next next);
  let fabricated =
    Session.Waiting.host_tool ~turn:(Session.Turn.id turn) tool_call
  in
  match fabricated with
  | Session.Waiting.Host_tool waiting -> (
      match
        Run.answer_host_tool config waiting ~text:"forged result"
          (Run.Step.session blocked)
      with
      | Ok _ -> failf "fabricated host-tool answer should be rejected"
      | Error (Run.Error.Tool_call_not_pending { call_id; name }) ->
          equal string ~msg:"error carries the call id" "call-1" call_id;
          equal string ~msg:"error carries the tool name" "review_tool" name
      | Error error -> failf "unexpected answer error: %a" Run.Error.pp error)
  | Session.Waiting.Permission _ | Session.Waiting.Tool_claim _ -> assert false

(* Regression: interrupting a turn that is waiting on a host-tool call (e.g. a
   user question) must synthesize an interrupted tool result for the unanswered
   call. Otherwise the saved transcript keeps an assistant tool call with no
   result and the provider rejects every subsequent request — the conversation
   wedges. A ready transcript is exactly what the next request builder needs. *)
let interrupt_answers_pending_host_tool_call () =
  let host_tool =
    Llm.Tool.make ~name:"ask_user" ~input_schema:(Json.object' []) ()
  in
  let turn =
    Session.Turn.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~input:(Session.Turn.Input.user_text "Use the host tool.")
      ~model ~declarations:[ host_tool ] ~host_tools:[ "ask_user" ]
      ~max_steps:max_int ()
  in
  let config = config ~host_tools:[ host_tool ] [] in
  let blocked =
    match
      Run.accept_response config
        (response (call ~id:"question-1" ~name:"ask_user" ()))
        (session_with turn)
    with
    | Ok step -> step
    | Error error -> failf "record response failed: %a" Run.Error.pp error
  in
  (match Run.Step.next blocked with
  | Run.Step.Waiting (Session.Waiting.Host_tool _) -> ()
  | next -> failf "expected host tool block, got %a" Run.Step.pp_next next);
  is_false ~msg:"the waiting transcript has an unanswered tool call"
    (Llm.Transcript.is_ready
       (Session.State.transcript (Session.state (Run.Step.session blocked))));
  match Run.interrupt ~reason:"cancelled" (Run.Step.session blocked) with
  | Error error -> failf "interrupt failed: %a" Run.Error.pp error
  | Ok step -> (
      equal int
        ~msg:
          "interrupt appends the synthesized tool result and the terminal event"
        2
        (List.length (Run.Step.events step));
      let state = Session.state (Run.Step.session step) in
      is_true
        ~msg:
          "the interrupted transcript is provider-well-formed (no pending tool \
           results)"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      (match Run.Step.next step with
      | Run.Step.Finished { outcome = Session.Turn.Outcome.Interrupted _; _ } ->
          ()
      | next ->
          failf "expected interrupted finish, got %a" Run.Step.pp_next next);
      let last_message =
        List.rev (Llm.Transcript.messages (Session.State.transcript state))
      in
      match last_message with
      | Llm.Message.Tool_result result :: _ ->
          equal string ~msg:"the synthesized result answers the question call"
            "question-1"
            (Llm.Tool.Result.call_id result);
          is_true ~msg:"the synthesized result is a tool error"
            (Llm.Tool.Result.is_error result)
      | _ -> failf "expected a tool result as the last transcript message")

(* A failed turn answers its unanswered calls for the same reason an
   interrupted one does: the transcript is saved, and the next turn's request
   carries it. An unanswered tool call there is rejected by the provider — so
   the turn that failed would poison the turns after it. *)
let fail_answers_pending_host_tool_call () =
  let host_tool =
    Llm.Tool.make ~name:"ask_user" ~input_schema:(Json.object' []) ()
  in
  let turn =
    Session.Turn.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~input:(Session.Turn.Input.user_text "Use the host tool.")
      ~model ~declarations:[ host_tool ] ~host_tools:[ "ask_user" ]
      ~max_steps:max_int ()
  in
  let config = config ~host_tools:[ host_tool ] [] in
  let blocked =
    match
      Run.accept_response config
        (response (call ~id:"question-1" ~name:"ask_user" ()))
        (session_with turn)
    with
    | Ok step -> step
    | Error error -> failf "record response failed: %a" Run.Error.pp error
  in
  match Run.fail ~message:"the provider is unavailable" (Run.Step.session blocked)
  with
  | Error error -> failf "fail failed: %a" Run.Error.pp error
  | Ok step -> (
      equal int
        ~msg:"fail appends the synthesized tool result and the terminal event" 2
        (List.length (Run.Step.events step));
      let state = Session.state (Run.Step.session step) in
      is_true
        ~msg:
          "the failed transcript is provider-well-formed (no pending tool \
           results)"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      match
        List.rev (Llm.Transcript.messages (Session.State.transcript state))
      with
      | Llm.Message.Tool_result result :: _ ->
          equal string ~msg:"the synthesized result answers the question call"
            "question-1"
            (Llm.Tool.Result.call_id result);
          is_true ~msg:"the synthesized result is a tool error"
            (Llm.Tool.Result.is_error result)
      | _ -> failf "expected a tool result as the last transcript message")

(* Regression companion: interrupting mid-drain, with an executable claim
   planned but not yet finished, finishes that claim with the interrupted
   result so the claim tracking and the transcript both stay consistent. *)
let interrupt_finishes_pending_claim () =
  let tool = executable_tool () in
  let policy =
    Permission.Policy.make [ Permission.Policy.Rule.allow_all_dangerously ]
  in
  let config = config ~policy [ tool ] in
  let claimed = run_response config (response (call ~id:"call-1" ())) in
  let claim = tool_claim_from_step claimed in
  is_true ~msg:"the claim is pending before interrupt"
    (Option.is_some
       (Session.State.pending_tool_claim
          (Session.Tool_claim.Started.id claim)
          (Session.state (Run.Step.session claimed))));
  match Run.interrupt ~reason:"cancelled" (Run.Step.session claimed) with
  | Error error -> failf "interrupt failed: %a" Run.Error.pp error
  | Ok step ->
      let state = Session.state (Run.Step.session step) in
      is_true
        ~msg:
          "the interrupted transcript is provider-well-formed after a pending \
           claim"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      (match Run.Step.events step with
      | [
       Session.Event.Tool_claim_finished finished;
       Session.Event.Turn_finished
         { outcome = Session.Turn.Outcome.Interrupted _; _ };
      ] ->
          is_true ~msg:"interrupt finishes the original claim id"
            (Session.Tool_claim.Id.equal
               (Session.Tool_claim.Started.id claim)
               (Session.Tool_claim.Finished.id finished));
          is_true ~msg:"interrupt records an error tool result"
            (Llm.Tool.Result.is_error
               (Session.Tool_claim.Finished.result finished));
          (match Session.State.tool_claims state with
          | [ (started, Some recorded) ] ->
              is_true ~msg:"claim history retains the original start"
                (Session.Tool_claim.Started.equal claim started);
              is_true ~msg:"claim history retains the interrupt finish"
                (Session.Tool_claim.Finished.equal finished recorded)
          | _ -> failf "expected one durably finished claim")
      | _ -> failf "interrupt did not durably finish the pending claim")

let policy_denial_uses_configured_message () =
  let deny_rule =
    Permission.Policy.Rule.deny (Permission.Policy.Match.kind `Custom)
  in
  let policy = Permission.Policy.make [ deny_rule ] in
  let seen = ref None in
  let denial_message denial =
    seen := Some (Permission.Policy.Denial.rule denial);
    "Custom denial steering."
  in
  let config =
    Run.Config.make ~tools:[ executable_tool () ] ~policy:(fun _ -> policy)
      ~denial_message ()
  in
  let step = run_response config (response (call ())) in
  (match Run.Step.next step with
  | Run.Step.Request_model _ -> ()
  | next ->
      failf "expected model request after policy denial, got %a"
        Run.Step.pp_next next);
  (match !seen with
  | Some rule ->
      is_true ~msg:"hook receives the denying rule"
        (Permission.Policy.Rule.equal rule deny_rule)
  | None -> failf "denial message hook was not called");
  let denial_texts =
    List.concat_map
      (function
        | Session.Event.Message_appended (Llm.Message.Tool_result result) ->
            Llm.Tool.Result.texts result
        | _ -> [])
      (Run.Step.events step)
  in
  equal (list string)
    ~msg:"denial text becomes the durable model-visible result"
    [ "Custom denial steering." ]
    denial_texts

let current_policy_is_checked_after_permission_allow () =
  let tool = executable_tool () in
  let blocked_config = config [ tool ] in
  let blocked = run_response blocked_config (response (call ())) in
  let request = permission_from_step blocked in
  let deny_rule =
    Permission.Policy.Rule.deny (Permission.Policy.Match.kind `Custom)
  in
  let deny_policy = Permission.Policy.make [ deny_rule ] in
  let deny_config =
    Run.Config.make ~tools:[ tool ] ~policy:(fun _ -> deny_policy)
      ~denial_message:(fun denial ->
        is_true ~msg:"current denial rule is applied"
          (Permission.Policy.Rule.equal deny_rule
             (Permission.Policy.Denial.rule denial));
        "Denied by current policy.")
      ()
  in
  match
    Run.resolve_permission deny_config
      (Session.Permission.Requested.id request)
      (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
      (Run.Step.session blocked)
  with
  | Error error ->
      failf "allow under changed policy failed: %a" Run.Error.pp error
  | Ok step -> (
      let state = Session.state (Run.Step.session step) in
      is_true ~msg:"policy denial answers the pending tool call"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      match Run.Step.next step with
      | Run.Step.Request_model _ -> ()
      | next ->
          failf "expected model request after current policy denial, got %a"
            Run.Step.pp_next next)

let permission_allow_requires_same_reviewed_accesses () =
  let first_access =
    Permission.Access.custom ~subject:"alpha" "review_tool"
  in
  let second_access =
    Permission.Access.custom ~subject:"beta" "review_tool"
  in
  let tool =
    let permissions () =
      [ Permission.Request.of_accesses [ first_access; second_access ] ]
    in
    Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
      ~input:Tool.Input.empty ~output ~permissions
      ~run:(fun _context () -> Tool.Result.completed ~output:() ())
      ()
  in
  let blocked = run_response (config [ tool ]) (response (call ())) in
  let first = permission_from_step blocked in
  let reviewed_accesses requested =
    Session.Permission.Requested.review requested
    |> Permission.Policy.Review.access_set
  in
  check "first review covers both accesses"
    (Permission.Access.Set.equal
       (reviewed_accesses first)
       (Permission.Access.Set.of_list [ first_access; second_access ]));
  let narrowed_policy =
    Permission.Policy.make
      [
        Permission.Policy.Rule.allow
          (Permission.Policy.Match.exact first_access);
      ]
  in
  let narrowed_config = config ~policy:narrowed_policy [ tool ] in
  match
    Run.resolve_permission narrowed_config
      (Session.Permission.Requested.id first)
      (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
      (Run.Step.session blocked)
  with
  | Error error ->
      failf "allow under narrowed policy failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Waiting (Session.Waiting.Permission second) ->
          check "narrowed review covers only the still-reviewed access"
            (Permission.Access.Set.equal
               (reviewed_accesses second)
               (Permission.Access.Set.of_list [ second_access ]))
      | next ->
          failf "expected narrowed permission review, got %a" Run.Step.pp_next
            next)

let resolved_value =
  testable ~pp:Session.Permission.Resolved.pp
    ~equal:Session.Permission.Resolved.equal ()

let unattended_denials_record_provenance () =
  let config = config [ executable_tool () ] in
  let blocked = run_response config (response (call ())) in
  let request = permission_from_step blocked in
  (match
     Run.resolve_permission config ~message:"Permission denied: unattended run."
       ~via:`Unattended
       (Session.Permission.Requested.id request)
       Session.Permission.Resolved.Deny (Run.Step.session blocked)
   with
  | Error error -> failf "unattended deny failed: %a" Run.Error.pp error
  | Ok step -> (
      let state = Session.state (Run.Step.session step) in
      match Session.State.permissions state with
      | [ (_, Some resolved) ] ->
          (match Session.Permission.Resolved.via resolved with
          | `Unattended -> ()
          | `Reviewer -> failf "expected unattended provenance");
          equal resolved_value ~msg:"unattended denial roundtrips" resolved
            (decode Session.Permission.Resolved.jsont
               (encode Session.Permission.Resolved.jsont resolved))
      | _ -> failf "expected one resolved permission"));
  (* Reviewer denials stay the default and decode from via-free JSON. *)
  let reviewer_blocked = run_response config (response (call ())) in
  let reviewer_request = permission_from_step reviewer_blocked in
  match
    Run.resolve_permission config
      (Session.Permission.Requested.id reviewer_request)
      Session.Permission.Resolved.Deny
      (Run.Step.session reviewer_blocked)
  with
  | Error error -> failf "reviewer deny failed: %a" Run.Error.pp error
  | Ok step -> (
      let state = Session.state (Run.Step.session step) in
      match Session.State.permissions state with
      | [ (_, Some resolved) ] -> (
          (match Session.Permission.Resolved.via resolved with
          | `Reviewer -> ()
          | `Unattended -> failf "expected reviewer provenance");
          let json = encode Session.Permission.Resolved.jsont resolved in
          equal resolved_value ~msg:"via-free JSON decodes as reviewer" resolved
            (decode Session.Permission.Resolved.jsont json);
          let bad =
            json_object
              [
                ("id", Json.string "permission-1");
                ("answer", Json.string "allow-once");
                ("via", Json.string "unattended");
              ]
          in
          match Json.decode Session.Permission.Resolved.jsont bad with
          | Ok _ -> failf "unattended provenance on an allow should be rejected"
          | Error _ -> ())
      | _ -> failf "expected one resolved permission")

let change_tool () =
  let permissions () =
    let access =
      Permission.Access.custom ~subject:"alpha" "review_tool"
    in
    [
      Permission.Request.make
        [
          Permission.Request.Item.make
            ~change:
              (Permission.Request.Change.make ~diff:"+line" ~additions:1 ())
            access;
        ];
    ]
  in
  Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
    ~input:Tool.Input.empty ~output ~permissions
    ~run:(fun _context () -> Tool.Result.completed ~output:() ())
    ()

let recomputed_change_keeps_allowed_permissions_matching () =
  let config = config [ change_tool () ] in
  let blocked = run_response config (response (call ())) in
  let request = permission_from_step blocked in
  match
    Run.resolve_permission config
      (Session.Permission.Requested.id request)
      (Session.Permission.Resolved.Allow Session.Permission.Resolved.Once)
      (Run.Step.session blocked)
  with
  | Error error -> failf "allow failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Run_tool _ -> ()
      | next ->
          failf "expected tool run after allow, got %a" Run.Step.pp_next next)

let () =
  run "spice.session.run"
    [
      test "config construction is programmer-local"
        config_construction_is_programmer_local;
      test "deterministic permission ids" deterministic_permission_ids;
      test "review bypass runs without a permission boundary"
        review_bypass_runs_without_a_permission_boundary;
      test "permission ids include request position"
        permission_ids_include_request_position;
      test "permission ids include full request"
        permission_ids_include_full_request;
      test "permission planner exceptions become tool errors"
        permission_planner_exceptions_become_tool_errors;
      test "staged preflight waits for preliminary permission"
        staged_preflight_waits_for_preliminary_permission;
      test "staged preflight checks final facts before claiming"
        staged_preflight_checks_final_facts_before_claiming;
      test "deterministic tool claim ids" deterministic_tool_claim_ids;
      test "finish tool uses saved claim id" finish_tool_uses_saved_claim_id;
      test "conversation family affects a later call in the same turn"
        conversation_family_affects_later_call_in_same_turn;
      test "accepted step limit cannot be widened"
        accepted_step_limit_cannot_be_widened;
      test "accepted step limit is resolved and clamped"
        accepted_step_limit_is_resolved_and_clamped;
      test "current step cap can tighten" current_step_cap_can_tighten;
      test "block accessors identify call and turn"
        block_accessors_identify_call_and_turn;
      test "interrupt finishes turn as cancelled"
        interrupt_finishes_turn_as_cancelled;
      test "fail finishes turn as failed" fail_finishes_turn_as_failed;
      test "config prelude reaches model request" prelude_reaches_model_request;
      test "resumed turn keeps accepted tool declarations"
        resumed_turn_keeps_accepted_tool_declarations;
      test "resumed turn rejects new executable tool"
        resumed_turn_rejects_new_executable_tool;
      test "automatic rejections preserve order"
        automatic_rejections_preserve_order;
      test "mixed call interrupt preserves boundaries"
        mixed_call_interrupt_preserves_boundaries;
      test "mixed call drains to host boundary"
        mixed_call_drains_to_host_boundary;
      test "accepted host tool keeps routing" accepted_host_tool_keeps_routing;
      test "turn tool contract is checked" turn_tool_contract_is_checked;
      test "resume requires active lifecycle" resume_requires_active_lifecycle;
      test "resolve permission deny answers blocked call"
        resolve_permission_deny_answers_blocked_call;
      test "answer tool records tool result" answer_tool_records_tool_result;
      test "host tool answer rejects executable call"
        host_tool_answer_rejects_executable_call;
      test "interrupt answers pending host tool call"
        interrupt_answers_pending_host_tool_call;
      test "fail answers pending host tool call"
        fail_answers_pending_host_tool_call;
      test "interrupt finishes pending claim" interrupt_finishes_pending_claim;
      test "policy denial uses configured message"
        policy_denial_uses_configured_message;
      test "current policy is checked after permission allow"
        current_policy_is_checked_after_permission_allow;
      test "permission allow requires same reviewed accesses"
        permission_allow_requires_same_reviewed_accesses;
      test "unattended denials record provenance"
        unattended_denials_record_provenance;
      test "recomputed change keeps allowed permissions matching"
        recomputed_change_keeps_allowed_permissions_matching;
    ]
