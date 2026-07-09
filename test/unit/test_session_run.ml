(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Session = Spice_session
module Run = Spice_session.Run
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

let turn =
  Session.Turn.make
    ~id:(Session.Turn.Id.of_string "turn-1")
    ~input:(Session.Turn.Input.user_text "Use the tool.")
    ~model ()

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
        [ Permission.Access.custom ~kind:`Write ~subject "review_tool" ];
    ]
  in
  Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
    ~input:Tool.Input.empty ~output ~permissions
    ~run:(fun _context () -> Tool.Result.completed ~output:() ())
    ()

let repeated_access_tool () =
  let access =
    Permission.Access.custom ~kind:`Write ~subject:"same" "review_tool"
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

let config ?(policy = Permission.Policy.default) ?host_tools ?prelude tools =
  Run.Config.make ~tools ?host_tools ~policy ?prelude ()

let config_construction_is_programmer_local () =
  expect_invalid_arg "non-positive max_steps raises" (fun () ->
      Run.Config.make ~tools:[] ~policy:Permission.Policy.default ~max_steps:0
        ());
  expect_invalid_arg "duplicate tool names raise" (fun () ->
      Run.Config.make
        ~tools:[ executable_tool (); executable_tool () ]
        ~policy:Permission.Policy.default ());
  let bad_name_tool =
    Tool.make ~name:"bad name" ~description:"Bad tool name."
      ~input:Tool.Input.empty ~output
      ~run:(fun _context () -> Tool.Result.completed ~output:() ())
      ()
  in
  expect_invalid_arg "invalid executable tool names raise" (fun () ->
      Run.Config.make ~tools:[ bad_name_tool ] ~policy:Permission.Policy.default
        ());
  let host_tool name =
    Llm.Tool.make ~name ~input_schema:(Json.object' []) ()
  in
  expect_invalid_arg "executable and host tool name collisions raise" (fun () ->
      Run.Config.make ~tools:[ executable_tool () ]
        ~host_tools:[ host_tool "review_tool" ]
        ~policy:Permission.Policy.default ());
  expect_invalid_arg "duplicate host tool names raise" (fun () ->
      Run.Config.make ~tools:[]
        ~host_tools:[ host_tool "ask_user"; host_tool "ask_user" ]
        ~policy:Permission.Policy.default ())

let permission_from_step step =
  match Run.Step.next step with
  | Run.Step.Waiting (Session.Waiting.Permission request) -> request
  | next -> failf "expected permission block, got %a" Run.Step.pp_next next

let run_response config response =
  match Run.accept_response config response (session ()) with
  | Ok step -> step
  | Error error -> failf "record response failed: %a" Run.Error.pp error

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
      (Permission.Policy.Review.Allow Permission.Policy.Review.Once)
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

let tool_claim_from_step step =
  match Run.Step.next step with
  | Run.Step.Run_tool { claim; call = _ } -> claim
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
    (Session.State.active_turn (Session.state (Run.Step.session step)));
  match Run.interrupt (empty_session ()) with
  | Ok _ -> failf "interrupt without active turn should fail"
  | Error Run.Error.No_active_turn -> ()
  | Error error -> failf "unexpected interrupt error: %a" Run.Error.pp error

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

let resolve_permission_deny_answers_blocked_call () =
  let config = config [ executable_tool () ] in
  let blocked = run_response config (response (call ())) in
  let request = permission_from_step blocked in
  let blocked_session = Run.Step.session blocked in
  (match
     Run.resolve_permission config
       (Session.Permission.Requested.id request)
       Permission.Policy.Review.Deny blocked_session
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
      (Permission.Policy.Review.Allow Permission.Policy.Review.Once)
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
      ~model ~host_tools:[ "ask_user" ] ()
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
      ~model ~host_tools:[ "ask_user" ] ()
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
  | Ok step ->
      equal int
        ~msg:"interrupt appends the synthesized tool result and the terminal \
              event"
        2
        (List.length (Run.Step.events step));
      let state = Session.state (Run.Step.session step) in
      is_true
        ~msg:"the interrupted transcript is provider-well-formed (no pending \
              tool results)"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      (match Run.Step.next step with
      | Run.Step.Finished { outcome = Session.Turn.Outcome.Interrupted _; _ } ->
          ()
      | next -> failf "expected interrupted finish, got %a" Run.Step.pp_next next);
      let last_message =
        List.rev (Llm.Transcript.messages (Session.State.transcript state))
      in
      (match last_message with
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
        ~msg:"the interrupted transcript is provider-well-formed after a \
              pending claim"
        (Llm.Transcript.is_ready (Session.State.transcript state));
      is_true ~msg:"the pending claim was finished by the interrupt"
        (Option.is_none
           (Session.State.pending_tool_claim
              (Session.Tool_claim.Started.id claim)
              state))

let policy_denial_uses_configured_message () =
  let deny_rule =
    Permission.Policy.Rule.deny (Permission.Policy.Match.kind `Write)
  in
  let policy = Permission.Policy.make [ deny_rule ] in
  let seen = ref None in
  let denial_message denial =
    seen := Some (Permission.Policy.Denial.rule denial);
    "Custom denial steering."
  in
  let config =
    Run.Config.make ~tools:[ executable_tool () ] ~policy ~denial_message ()
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
    Permission.Policy.Rule.deny (Permission.Policy.Match.kind `Write)
  in
  let deny_policy = Permission.Policy.make [ deny_rule ] in
  let deny_config =
    Run.Config.make ~tools:[ tool ] ~policy:deny_policy
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
      (Permission.Policy.Review.Allow Permission.Policy.Review.Once)
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
    Permission.Access.custom ~kind:`Write ~subject:"alpha" "review_tool"
  in
  let second_access =
    Permission.Access.custom ~kind:`Write ~subject:"beta" "review_tool"
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
  check "first review covers both accesses"
    (Permission.Access.Set.equal
       (Session.Permission.Requested.asked first)
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
      (Permission.Policy.Review.Allow Permission.Policy.Review.Once)
      (Run.Step.session blocked)
  with
  | Error error ->
      failf "allow under narrowed policy failed: %a" Run.Error.pp error
  | Ok step -> (
      match Run.Step.next step with
      | Run.Step.Waiting (Session.Waiting.Permission second) ->
          check "narrowed review covers only the still-reviewed access"
            (Permission.Access.Set.equal
               (Session.Permission.Requested.asked second)
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
       Permission.Policy.Review.Deny (Run.Step.session blocked)
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
      Permission.Policy.Review.Deny
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
      Permission.Access.custom ~kind:`Write ~subject:"alpha" "review_tool"
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
      (Permission.Policy.Review.Allow Permission.Policy.Review.Once)
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
      test "permission ids include request position"
        permission_ids_include_request_position;
      test "permission planner exceptions become tool errors"
        permission_planner_exceptions_become_tool_errors;
      test "deterministic tool claim ids" deterministic_tool_claim_ids;
      test "block accessors identify call and turn"
        block_accessors_identify_call_and_turn;
      test "interrupt finishes turn as cancelled"
        interrupt_finishes_turn_as_cancelled;
      test "config prelude reaches model request" prelude_reaches_model_request;
      test "resolve permission deny answers blocked call"
        resolve_permission_deny_answers_blocked_call;
      test "answer tool records tool result" answer_tool_records_tool_result;
      test "host tool answer rejects executable call"
        host_tool_answer_rejects_executable_call;
      test "interrupt answers pending host tool call"
        interrupt_answers_pending_host_tool_call;
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
