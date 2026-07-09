(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap

let obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let str = Jsont.Json.string

(* Host-tool call classification. *)
module Call_tests = struct
  module Call = Spice_protocol.Call
  module Llm = Spice_llm

  let call ~name ~input = Llm.Tool.Call.make ~id:"call-1" ~name ~input ()
  let question_input = obj [ ("question", str "Why?") ]
  let plan_input = obj [ ("id", str "plan-1"); ("body", str "Do the thing.") ]
  let todo_input = obj [ ("todos", Jsont.Json.list []) ]
  let goal_input = obj [ ("status", str "complete") ]
  let subagent_input = obj [ ("role", str "explore"); ("task", str "Look.") ]

  let subagent_wait_input =
    obj [ ("runs", Jsont.Json.list [ str "ses-child-1" ]) ]

  let subagent_cancel_input = obj [ ("run", str "ses-child-1") ]

  let subagent_message_input =
    obj [ ("run", str "ses-child-1"); ("message", str "focus on lib/") ]

  let subagent_message_parent_input =
    obj [ ("message", str "which of the two configs wins?") ]

  let classify_recognizes_each_host_tool () =
    (match Call.classify (call ~name:"ask_user" ~input:question_input) with
    | Some (Call.Question _) -> ()
    | other ->
        failf "ask_user should classify as Question, got %a"
          (Format.pp_print_option Call.pp)
          other);
    (match Call.classify (call ~name:"propose_plan" ~input:plan_input) with
    | Some (Call.Plan _) -> ()
    | other ->
        failf "propose_plan should classify as Plan, got %a"
          (Format.pp_print_option Call.pp)
          other);
    (match Call.classify (call ~name:"todo_write" ~input:todo_input) with
    | Some (Call.Todo _) -> ()
    | other ->
        failf "todo_write should classify as Todo, got %a"
          (Format.pp_print_option Call.pp)
          other);
    (match Call.classify (call ~name:"update_goal" ~input:goal_input) with
    | Some (Call.Goal _) -> ()
    | other ->
        failf "update_goal should classify as Goal, got %a"
          (Format.pp_print_option Call.pp)
          other);
    (match
       Call.classify (call ~name:"spawn_subagent" ~input:subagent_input)
     with
    | Some (Call.Subagent _) -> ()
    | other ->
        failf "spawn_subagent should classify as Subagent, got %a"
          (Format.pp_print_option Call.pp)
          other);
    (match
       Call.classify (call ~name:"wait_subagents" ~input:subagent_wait_input)
     with
    | Some (Call.Subagent_wait _) -> ()
    | other ->
        failf "wait_subagents should classify as Subagent_wait, got %a"
          (Format.pp_print_option Call.pp)
          other);
    match
      Call.classify (call ~name:"cancel_subagent" ~input:subagent_cancel_input)
    with
    | Some (Call.Subagent_cancel _) -> ()
    | other ->
        failf "cancel_subagent should classify as Subagent_cancel, got %a"
          (Format.pp_print_option Call.pp)
          other

  let classify_reports_invalid_with_tool_name () =
    let cases =
      [
        ("ask_user", obj [ ("question", str "") ]);
        ("propose_plan", obj [ ("id", str "p"); ("body", str "") ]);
        ("todo_write", obj [ ("todos", str "not-an-array") ]);
        ("update_goal", obj [ ("status", str "paused") ]);
        ("spawn_subagent", obj [ ("role", str "explore"); ("task", str "") ]);
        ("wait_subagents", obj [ ("runs", Jsont.Json.list []) ]);
        ("message_subagent", obj [ ("run", str "r"); ("message", str "") ]);
        ("message_parent", obj [ ("message", str "") ]);
      ]
    in
    List.iter
      (fun (name, input) ->
        match Call.classify (call ~name ~input) with
        | Some (Call.Invalid { name = reported; error }) ->
            equal string ~msg:"Invalid carries the tool name" name reported;
            is_true ~msg:"Invalid carries a non-empty diagnostic"
              (not (String.is_empty error))
        | other ->
            failf "%s with a bad payload should be Invalid, got %a" name
              (Format.pp_print_option Call.pp)
              other)
      cases

  let classify_returns_none_for_non_host_tools () =
    equal (option string) ~msg:"executable tools are not host calls" None
      (Option.map
         (fun _ -> "host")
         (Call.classify (call ~name:"read_file" ~input:(obj []))))

  let kind_and_classify_agree () =
    let input_of = function
      | Call.Kind.Question -> question_input
      | Call.Kind.Plan -> plan_input
      | Call.Kind.Todo -> todo_input
      | Call.Kind.Goal -> goal_input
      | Call.Kind.Subagent -> subagent_input
      | Call.Kind.Subagent_wait -> subagent_wait_input
      | Call.Kind.Subagent_cancel -> subagent_cancel_input
      | Call.Kind.Subagent_message -> subagent_message_input
      | Call.Kind.Subagent_message_parent -> subagent_message_parent_input
    in
    let classifies_to kind = function
      | Call.Question _ -> Call.Kind.equal kind Call.Kind.Question
      | Call.Plan _ -> Call.Kind.equal kind Call.Kind.Plan
      | Call.Todo _ -> Call.Kind.equal kind Call.Kind.Todo
      | Call.Goal _ -> Call.Kind.equal kind Call.Kind.Goal
      | Call.Subagent _ -> Call.Kind.equal kind Call.Kind.Subagent
      | Call.Subagent_wait _ -> Call.Kind.equal kind Call.Kind.Subagent_wait
      | Call.Subagent_cancel _ -> Call.Kind.equal kind Call.Kind.Subagent_cancel
      | Call.Subagent_message _ ->
          Call.Kind.equal kind Call.Kind.Subagent_message
      | Call.Subagent_message_parent _ ->
          Call.Kind.equal kind Call.Kind.Subagent_message_parent
      | Call.Invalid _ -> false
    in
    List.iter
      (fun kind ->
        let name = Call.Kind.name kind in
        match Call.classify (call ~name ~input:(input_of kind)) with
        | Some classified ->
            is_true
              ~msg:(Printf.sprintf "a %s call classifies to kind %s" name name)
              (classifies_to kind classified)
        | None -> failf "kind %s built call should classify" name)
      Call.Kind.all

  let kind_all_is_the_full_recognition_set () =
    equal (list string) ~msg:"Kind.all is every host tool declaration"
      [
        "ask_user";
        "propose_plan";
        "todo_write";
        "update_goal";
        "spawn_subagent";
        "wait_subagents";
        "cancel_subagent";
        "message_subagent";
        "message_parent";
      ]
      (List.map
         (fun kind -> Llm.Tool.name (Call.Kind.tool kind))
         Call.Kind.all)

  let answerable_question_folds_valid_and_invalid () =
    let valid =
      Option.get (Call.classify (call ~name:"ask_user" ~input:question_input))
    in
    equal (option string) ~msg:"valid question is answerable with its text"
      (Some "Why?")
      (Call.answerable_question valid);
    let invalid =
      Option.get
        (Call.classify
           (call ~name:"ask_user" ~input:(obj [ ("question", str "") ])))
    in
    (match Call.answerable_question invalid with
    | Some text ->
        is_true ~msg:"invalid question stays answerable with a description"
          (String.length text > 0
          && String.equal
               (String.sub text 0 (min 17 (String.length text)))
               "Invalid question:")
    | None -> failf "invalid question should still be answerable");
    let plan =
      Option.get (Call.classify (call ~name:"propose_plan" ~input:plan_input))
    in
    equal (option string) ~msg:"non-question calls are not answerable questions"
      None
      (Call.answerable_question plan)

  let plan_proposal_rejects_invalid () =
    let valid =
      Option.get (Call.classify (call ~name:"propose_plan" ~input:plan_input))
    in
    is_true ~msg:"a well-formed proposal is a plan proposal"
      (Option.is_some (Call.plan_proposal valid));
    let invalid =
      Option.get
        (Call.classify
           (call ~name:"propose_plan"
              ~input:(obj [ ("id", str "p"); ("body", str "") ])))
    in
    equal (option string) ~msg:"an invalid proposal is not a plan proposal" None
      (Option.map (fun _ -> "plan") (Call.plan_proposal invalid))

  let answer_text_is_call_specific () =
    let classified name input =
      Option.get (Call.classify (call ~name ~input))
    in
    equal (result string string) ~msg:"questions use canonical answer wording"
      (Ok "User answered: yes")
      (Call.answer_text (classified "ask_user" question_input) "yes");
    equal (result string string) ~msg:"parent messages remain verbatim"
      (Ok "focus here")
      (Call.answer_text
         (classified "message_parent" subagent_message_parent_input)
         "focus here");
    is_true ~msg:"plans cannot be resolved through a generic answer"
      (Result.is_error
         (Call.answer_text (classified "propose_plan" plan_input) "yes"))

  let tool_schemas_require_checked_strings () =
    let member name = function
      | Jsont.Object (members, _) ->
          Option.map snd (Jsont.Json.find_mem name members)
      | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Array _ ->
          None
    in
    let property tool name =
      Spice_llm.Tool.input_schema tool |> member "properties"
      |> fun properties -> Option.bind properties (member name)
    in
    let expected =
      obj [ ("type", str "string"); ("minLength", Jsont.Json.int 1) ]
    in
    let check message tool name =
      is_true ~msg:message
        (Option.exists (Jsont.Json.equal expected) (property tool name))
    in
    check "question schema rejects empty questions" Spice_protocol.Question.tool
      "question";
    check "plan schema rejects empty bodies" Spice_protocol.Plan.tool "body";
    check "spawn schema rejects empty tasks" Spice_protocol.Subagent.tool "task";
    check "message schema rejects empty messages"
      Spice_protocol.Subagent.Message.tool "message"

  let suite =
    group "call"
      [
        test "classify recognizes each host tool"
          classify_recognizes_each_host_tool;
        test "classify reports Invalid with the tool name"
          classify_reports_invalid_with_tool_name;
        test "classify returns None for non-host tools"
          classify_returns_none_for_non_host_tools;
        test "Kind and classify agree" kind_and_classify_agree;
        test "Kind.all is the full recognition set"
          kind_all_is_the_full_recognition_set;
        test "answerable_question folds valid and invalid"
          answerable_question_folds_valid_and_invalid;
        test "answer text is call-specific" answer_text_is_call_specific;
        test "tool schemas require checked strings"
          tool_schemas_require_checked_strings;
        test "plan_proposal rejects Invalid" plan_proposal_rejects_invalid;
      ]
end

(* Primary turn modes. *)
module Mode_tests = struct
  module Mode = Spice_protocol.Mode
  module Call = Spice_protocol.Call
  module Contract = Spice_protocol.Contract
  module Subagent = Spice_protocol.Subagent
  module Session = Spice_session
  module Llm = Spice_llm

  let model =
    Llm.Model.make
      ~provider:(Llm.Provider.make "openai")
      ~api:(Llm.Model.Api.make "responses")
      ~id:"gpt-5"

  let turn ?mode () =
    Session.Turn.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~input:(Session.Turn.Input.user_text "Go.")
      ~model ?mode ()

  let kind_names kinds = List.map Call.Kind.name kinds

  let of_string_parses_and_reports_candidates () =
    equal (option string) ~msg:"build parses" (Some "build")
      (Result.to_option (Result.map Mode.to_string (Mode.of_string "build")));
    match Mode.of_string "plann" with
    | Ok _ -> failf "an unknown spelling should fail"
    | Error err ->
        equal string ~msg:"parse error echoes the input" "plann" err.Mode.input;
        equal (list string) ~msg:"parse error carries the candidates"
          [ "build"; "plan"; "review" ]
          err.Mode.candidates

  let of_turn_degrades_to_default () =
    equal string ~msg:"absent mode degrades to build" "build"
      (Mode.to_string (Mode.of_turn (turn ())));
    equal string ~msg:"unknown mode degrades to build" "build"
      (Mode.to_string (Mode.of_turn (turn ~mode:"nonsense" ())));
    equal string ~msg:"known mode is preserved" "plan"
      (Mode.to_string (Mode.of_turn (turn ~mode:"plan" ())))

  let host_tools_offer_table () =
    equal (list string) ~msg:"build offers question, todo, goal, subagent"
      [
        "ask_user";
        "todo_write";
        "update_goal";
        "spawn_subagent";
        "wait_subagents";
        "cancel_subagent";
        "message_subagent";
      ]
      (kind_names (Mode.host_tools Mode.Build));
    equal (list string) ~msg:"plan offers question, plan, subagent"
      [
        "ask_user";
        "propose_plan";
        "spawn_subagent";
        "wait_subagents";
        "cancel_subagent";
        "message_subagent";
      ]
      (kind_names (Mode.host_tools Mode.Plan));
    equal (list string) ~msg:"review offers question, subagent"
      [
        "ask_user";
        "spawn_subagent";
        "wait_subagents";
        "cancel_subagent";
        "message_subagent";
      ]
      (kind_names (Mode.host_tools Mode.Review))

  let allows_role_matrix () =
    let roles = Subagent.Role.[ Explore; Review; Verify ] in
    equal (list bool) ~msg:"build allows every role" [ true; true; true ]
      (List.map (Mode.allows_role Mode.Build) roles);
    equal (list bool) ~msg:"plan allows only explore" [ true; false; false ]
      (List.map (Mode.allows_role Mode.Plan) roles);
    equal (list bool) ~msg:"review allows only explore" [ true; false; false ]
      (List.map (Mode.allows_role Mode.Review) roles)

  let contract_mapping () =
    is_true ~msg:"build is unrestricted"
      (Contract.equal (Mode.contract Mode.Build) Contract.unrestricted);
    is_true ~msg:"plan is read-only"
      (Contract.equal (Mode.contract Mode.Plan) Contract.read_only);
    is_true ~msg:"review is read-only"
      (Contract.equal (Mode.contract Mode.Review) Contract.read_only)

  let suite =
    group "mode"
      [
        test "of_string parses and reports candidates"
          of_string_parses_and_reports_candidates;
        test "of_turn degrades to default" of_turn_degrades_to_default;
        test "host_tools offer table" host_tools_offer_table;
        test "allows_role matrix" allows_role_matrix;
        test "contract mapping" contract_mapping;
      ]
end

(* The read-only contract. *)
module Contract_tests = struct
  open Test_support
  module Contract = Spice_protocol.Contract
  module Tool = Spice_tool
  module Permission = Spice_permission
  module Json = Jsont.Json

  let schema =
    json_object
      [
        ("type", Json.string "object");
        ( "properties",
          json_object
            [ ("text", json_object [ ("type", Json.string "string") ]) ] );
        ("required", json_array [ Json.string "text" ]);
        ("additionalProperties", Json.bool false);
      ]

  let string_input =
    Jsont.Object.map ~kind:"tool input" Fun.id
    |> Jsont.Object.mem "text" Jsont.string ~enc:Fun.id
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Tool.Input.make ~schema

  let output () = Tool.Output.make ~text:"ok" ()

  let tool name =
    Tool.make ~name ~description:"A test tool." ~input:string_input ~output
      ~run:(fun _context _input -> Tool.Result.completed ~output:() ())
      ()

  let all_names =
    [ "read_file"; "search_text"; "glob"; "skill"; "shell"; "write_file" ]

  let all_tools = List.map tool all_names

  let kept contract =
    List.map Tool.name (Contract.filter_tools contract all_tools)

  let filter_tools_by_contract () =
    equal (list string) ~msg:"unrestricted keeps every tool in order" all_names
      (kept Contract.unrestricted);
    equal (list string) ~msg:"read_only keeps only discovery tools"
      [ "read_file"; "search_text"; "glob"; "skill" ]
      (kept Contract.read_only);
    equal (list string) ~msg:"checks keeps discovery plus shell"
      [ "read_file"; "search_text"; "glob"; "skill"; "shell" ]
      (kept Contract.checks)

  let policy_strengthening () =
    let configured = Permission.Policy.default in
    is_true ~msg:"unrestricted returns the configured policy unchanged"
      (Permission.Policy.equal configured
         (Contract.policy Contract.unrestricted ~configured));
    is_true ~msg:"checks returns the configured policy unchanged"
      (Permission.Policy.equal configured
         (Contract.policy Contract.checks ~configured));
    is_true ~msg:"read_only overrides the configured policy"
      (not
         (Permission.Policy.equal configured
            (Contract.policy Contract.read_only ~configured)));
    is_true ~msg:"read_only ignores the configured policy it strengthens"
      (Permission.Policy.equal
         (Contract.policy Contract.read_only ~configured)
         (Contract.policy Contract.read_only
            ~configured:(Permission.Policy.make [])))

  let suite =
    group "contract"
      [
        test "filter_tools by contract" filter_tools_by_contract;
        test "policy strengthening" policy_strengthening;
      ]
end

(* Artifact vocabulary: plan, todo, subagent, subagent_run, question. *)
module Artifacts_tests = struct
  module Plan = Spice_protocol.Plan
  module Todo = Spice_protocol.Todo
  module Subagent = Spice_protocol.Subagent
  module Subagent_run = Spice_protocol.Subagent_run
  module Question = Spice_protocol.Question
  module Session = Spice_session
  module Llm = Spice_llm

  let time ms = Session.Time.of_unix_ms (Int64.of_int ms)

  let ok msg = function
    | Ok v -> v
    | Error e -> failf "%s: unexpected error: %s" msg e

  let is_error msg = function
    | Ok _ -> failf "%s: expected an error" msg
    | Error _ -> ()

  let round_trip ~msg ~equal:eq jsont value =
    match Jsont.Json.encode jsont value with
    | Error e -> failf "%s: encode failed: %s" msg e
    | Ok json -> (
        match Jsont.Json.decode jsont json with
        | Error e -> failf "%s: decode failed: %s" msg e
        | Ok decoded -> is_true ~msg (eq value decoded))

  let call ~name ~input = Llm.Tool.Call.make ~id:"c1" ~name ~input ()

  (* Plan *)

  let plan_source () =
    ok "plan source"
      (Plan.Source.make
         ~session:(Session.Id.of_string "session-1")
         ~turn:(Session.Turn.Id.of_string "turn-1")
         ())

  let a_plan () =
    ok "propose"
      (Plan.propose
         ~id:(ok "plan id" (Plan.Id.of_string "plan-1"))
         ~source:(plan_source ()) ~title:"Title" ~body:"Body."
         ~created_at:(time 10) ())

  let plan_rejections () =
    is_error "empty plan id" (Plan.Id.of_string "");
    is_error "empty plan body"
      (Plan.propose
         ~id:(ok "id" (Plan.Id.of_string "p"))
         ~source:(plan_source ()) ~body:"" ~created_at:(time 1) ());
    is_error "empty plan title"
      (Plan.propose
         ~id:(ok "id" (Plan.Id.of_string "p"))
         ~source:(plan_source ()) ~title:"" ~body:"Body." ~created_at:(time 1)
         ())

  let plan_transitions () =
    let plan = a_plan () in
    let approved = ok "approve" (Plan.approve ~approved_at:(time 20) plan) in
    is_true ~msg:"approved plan is approved"
      (Plan.Status.is_approved (Plan.status approved));
    is_error "cannot re-approve" (Plan.approve ~approved_at:(time 30) approved);
    is_error "cannot approve before creation"
      (Plan.approve ~approved_at:(time 5) plan);
    let rejected =
      ok "reject" (Plan.reject ~rejected_at:(time 20) ~reason:"nope" plan)
    in
    is_true ~msg:"rejected plan is rejected"
      (Plan.Status.is_rejected (Plan.status rejected));
    is_error "empty reject reason"
      (Plan.reject ~rejected_at:(time 20) ~reason:"" plan);
    let by = ok "by id" (Plan.Id.of_string "plan-2") in
    is_error "cannot supersede before the previous transition"
      (Plan.supersede ~superseded_at:(time 15) ~by approved);
    is_true ~msg:"approved plan may be superseded"
      (Result.is_ok (Plan.supersede ~superseded_at:(time 25) ~by approved));
    let superseded =
      ok "supersede" (Plan.supersede ~superseded_at:(time 25) ~by plan)
    in
    is_error "cannot supersede a superseded plan"
      (Plan.supersede ~superseded_at:(time 26)
         ~by:(ok "id3" (Plan.Id.of_string "plan-3"))
         superseded);
    is_error "cannot supersede itself"
      (Plan.supersede ~superseded_at:(time 25) ~by:(Plan.id plan) plan)

  let plan_round_trips () =
    round_trip ~msg:"plan jsont round-trips" ~equal:Plan.equal Plan.jsont
      (ok "approve" (Plan.approve ~approved_at:(time 30) (a_plan ())))

  let plan_decode_rejects_self_supersession () =
    let json by =
      Printf.sprintf
        {|{"id":"plan-1","source":{"session":"session-1","turn":"turn-1"},"body":"Body.","status":{"type":"superseded","superseded_at":20,"by":"%s"},"created_at":10}|}
        by
    in
    (match Jsont_bytesrw.decode_string Plan.jsont (json "plan-1") with
    | Error _ -> ()
    | Ok _ -> failf "self-superseding stored plan should be rejected");
    match Jsont_bytesrw.decode_string Plan.jsont (json "plan-2") with
    | Ok _ -> ()
    | Error error -> failf "valid superseding plan should decode: %s" error

  let plan_decode_prose () =
    is_true ~msg:"propose_plan decode error is model-visible prose"
      (match
         Plan.decode
           (call ~name:"propose_plan"
              ~input:(obj [ ("id", str "p"); ("body", str "") ]))
       with
      | Error e -> not (String.is_empty e)
      | Ok _ -> false);
    is_error "wrong tool name is rejected"
      (Plan.decode (call ~name:"read_file" ~input:(obj [])))

  let plan_decision () =
    is_true ~msg:"decisions compare structurally"
      (Plan.Decision.equal Plan.Decision.approve Plan.Decision.approve
      && not (Plan.Decision.equal Plan.Decision.approve Plan.Decision.reject));
    is_error "empty rejection reason"
      (Plan.Decision.reject_with_reason "");
    is_true ~msg:"decision pp is non-empty"
      (not
         (String.is_empty
            (Format.asprintf "%a" Plan.Decision.pp
               (match Plan.Decision.reject_with_reason "nope" with
               | Ok decision -> decision
               | Error _ -> failwith "valid rejection reason"))))

  (* Todo *)

  let todo_item ?(owner = "main") ?(status = Todo.Status.Pending) ~id ~position
      () =
    ok "todo item"
      (Todo.Item.make
         ~id:(ok "todo id" (Todo.Id.of_string id))
         ~owner:(ok "owner" (Todo.Owner.of_string owner))
         ~content:("do " ^ id) ~status ~position ())

  let todo_rejections () =
    is_error "empty todo id" (Todo.Id.of_string "");
    is_error "empty todo content"
      (Todo.Item.make
         ~id:(ok "id" (Todo.Id.of_string "t"))
         ~content:"" ~position:0 ());
    is_error "negative todo position"
      (Todo.Item.make
         ~id:(ok "id" (Todo.Id.of_string "t"))
         ~content:"c" ~position:(-1) ());
    is_error "duplicate ids"
      (Todo.make
         [ todo_item ~id:"t" ~position:0 (); todo_item ~id:"t" ~position:1 () ]);
    is_error "non-contiguous positions"
      (Todo.make
         [ todo_item ~id:"a" ~position:0 (); todo_item ~id:"b" ~position:2 () ]);
    is_error "two in-progress for one owner"
      (Todo.make
         [
           todo_item ~id:"a" ~position:0 ~status:Todo.Status.In_progress ();
           todo_item ~id:"b" ~position:1 ~status:Todo.Status.In_progress ();
         ])

  let todo_round_trips () =
    let todos =
      ok "make"
        (Todo.make
           [
             todo_item ~id:"a" ~position:0 ~status:Todo.Status.In_progress ();
             todo_item ~id:"b" ~position:1 ();
           ])
    in
    round_trip ~msg:"todo jsont round-trips" ~equal:Todo.equal Todo.jsont todos

  let todo_decode_prose () =
    is_true ~msg:"todo_write decode error is prose"
      (match
         Todo.decode
           (call ~name:"todo_write" ~input:(obj [ ("todos", str "bad") ]))
       with
      | Error e -> not (String.is_empty e)
      | Ok _ -> false)

  (* Subagent *)

  let a_spawn () =
    ok "spawn"
      (Subagent.Spawn.make ~role:Subagent.Role.Explore ~task:"Investigate."
         ~scope:[ "lib/" ] ~expected_output:"A finding." ())

  let subagent_rejections () =
    is_error "empty task"
      (Subagent.Spawn.make ~role:Subagent.Role.Explore ~task:"" ());
    is_error "empty scope entry"
      (Subagent.Spawn.make ~role:Subagent.Role.Explore ~task:"t" ~scope:[ "" ]
         ());
    is_error "empty expected output"
      (Subagent.Spawn.make ~role:Subagent.Role.Explore ~task:"t"
         ~expected_output:"" ())

  let subagent_round_trips () =
    round_trip ~msg:"spawn jsont round-trips" ~equal:Subagent.Spawn.equal
      Subagent.Spawn.jsont (a_spawn ())

  let subagent_decode_prose () =
    is_true ~msg:"unknown role decode is prose"
      (match
         Subagent.decode
           (call ~name:"spawn_subagent"
              ~input:(obj [ ("role", str "wizard"); ("task", str "t") ]))
       with
      | Error e -> not (String.is_empty e)
      | Ok _ -> false)

  (* Subagent_run *)

  let a_run () =
    ok "run"
      (Subagent_run.make
         ~child:(Session.Id.of_string "child-1")
         ~parent:(Session.Id.of_string "parent-1")
         ~parent_turn:(Session.Turn.Id.of_string "turn-1")
         ~parent_call_id:"call-1" ~spawn:(a_spawn ()) ~depth:1
         ~created_at:(time 10) ())

  let run_rejections () =
    is_error "empty parent call id"
      (Subagent_run.make ~child:(Session.Id.of_string "c")
         ~parent:(Session.Id.of_string "p")
         ~parent_turn:(Session.Turn.Id.of_string "turn-1")
         ~parent_call_id:"" ~spawn:(a_spawn ()) ~depth:1 ~created_at:(time 10)
         ());
    is_error "negative depth"
      (Subagent_run.make ~child:(Session.Id.of_string "c")
         ~parent:(Session.Id.of_string "p")
         ~parent_turn:(Session.Turn.Id.of_string "turn-1")
         ~parent_call_id:"call" ~spawn:(a_spawn ()) ~depth:(-1)
         ~created_at:(time 10) ())

  let run_transitions () =
    let run = a_run () in
    let started = ok "start" (Subagent_run.start ~started_at:(time 20) run) in
    is_error "cannot start twice"
      (Subagent_run.start ~started_at:(time 30) started);
    is_error "cannot complete before the previous transition"
      (Subagent_run.complete ~completed_at:(time 15) ~summary:"done" started);
    let blocked =
      ok "block"
        (Subagent_run.block ~blocked_at:(time 25) ~blocker:"waiting" started)
    in
    is_error "empty blocker"
      (Subagent_run.block ~blocked_at:(time 25) ~blocker:"" started);
    let completed =
      ok "complete"
        (Subagent_run.complete ~completed_at:(time 40) ~summary:"done" blocked)
    in
    is_true ~msg:"completed run is terminal"
      (String.equal
         (Subagent_run.Status.to_string (Subagent_run.status completed))
         "completed");
    is_error "cannot fail a completed run"
      (Subagent_run.fail ~failed_at:(time 50) ~message:"boom" completed);
    is_error "cannot complete a queued run"
      (Subagent_run.complete ~completed_at:(time 20) ~summary:"x" run)

  let run_round_trips () =
    round_trip ~msg:"subagent run jsont round-trips" ~equal:Subagent_run.equal
      Subagent_run.jsont
      (ok "block"
         (Subagent_run.block ~blocked_at:(time 25) ~blocker:"waiting"
            (ok "start" (Subagent_run.start ~started_at:(time 20) (a_run ())))))

  let run_cancel () =
    let started =
      ok "start" (Subagent_run.start ~started_at:(time 20) (a_run ()))
    in
    let cancelled =
      ok "cancel" (Subagent_run.cancel ~cancelled_at:(time 30) started)
    in
    is_true ~msg:"cancelled run is terminal, not failed"
      (String.equal
         (Subagent_run.Status.to_string (Subagent_run.status cancelled))
         "cancelled");
    is_error "cannot complete a cancelled run"
      (Subagent_run.complete ~completed_at:(time 40) ~summary:"x" cancelled);
    is_error "cannot cancel a completed run"
      (Subagent_run.cancel ~cancelled_at:(time 50)
         (ok "complete"
            (Subagent_run.complete ~completed_at:(time 40) ~summary:"done"
               started)));
    (* A queued run can be cancelled directly, like fail. *)
    let queued_cancel =
      ok "cancel queued"
        (Subagent_run.cancel ~cancelled_at:(time 15) (a_run ()))
    in
    is_true ~msg:"queued run cancels"
      (String.equal
         (Subagent_run.Status.to_string (Subagent_run.status queued_cancel))
         "cancelled")

  let run_usage_round_trips () =
    let usage =
      match
        Subagent_run.Usage.make ~prompt_tokens:1200 ~completion_tokens:3400
          ~tool_uses:14
      with
      | Ok usage -> usage
      | Error error ->
          failf "valid usage was rejected: %a" Subagent_run.Usage.pp_error error
    in
    let started =
      ok "start" (Subagent_run.start ~started_at:(time 20) (a_run ()))
    in
    round_trip ~msg:"completed run with usage round-trips"
      ~equal:Subagent_run.equal Subagent_run.jsont
      (ok "complete"
         (Subagent_run.complete ~completed_at:(time 40) ~summary:"done" ~usage
            started));
    round_trip ~msg:"cancelled run with usage round-trips"
      ~equal:Subagent_run.equal Subagent_run.jsont
      (ok "cancel" (Subagent_run.cancel ~cancelled_at:(time 30) ~usage started));
    let completed =
      ok "complete"
        (Subagent_run.complete ~completed_at:(time 40) ~summary:"done" ~usage
           started)
    in
    match Subagent_run.usage completed with
    | Some recorded ->
        is_true ~msg:"usage accessor returns the record"
          (Subagent_run.Usage.equal usage recorded)
    | None -> failf "usage accessor lost the record"

  let run_usage_rejections () =
    match
      Subagent_run.Usage.make ~prompt_tokens:(-1) ~completion_tokens:0
        ~tool_uses:0
    with
    | Error
        (Subagent_run.Usage.Negative_count
          { field = Subagent_run.Usage.Prompt_tokens; value = -1 }) ->
        ()
    | Error error ->
        failf "negative usage returned the wrong error: %a"
          Subagent_run.Usage.pp_error error
    | Ok _ -> failf "negative usage should be rejected"

  (* A run file written before usage/cancelled existed decodes with
     [usage = None] — additive optional members keep old ledgers readable. *)
  let run_legacy_decode () =
    let json =
      {|{"child":"child-1","parent":"parent-1","parent_turn":"turn-1","parent_call_id":"call-1","spawn":{"role":"explore","task":"Look."},"depth":1,"status":{"type":"completed","completed_at":40,"summary":"done"},"created_at":10}|}
    in
    match Jsont_bytesrw.decode_string Subagent_run.jsont json with
    | Error e -> failf "legacy run decode failed: %s" e
    | Ok run -> (
        is_true ~msg:"legacy run has no usage"
          (Option.is_none (Subagent_run.usage run));
        match Subagent_run.status run with
        | Subagent_run.Status.Completed { summary; _ } ->
            is_true ~msg:"legacy summary survives" (String.equal summary "done")
        | _ -> failf "legacy run decoded to the wrong status")

  (* Goal *)

  module Goal = Spice_protocol.Goal

  let a_goal ?token_budget () =
    ok "set goal"
      (Goal.set
         ~id:(ok "goal id" (Goal.Id.of_string "goal-1"))
         ~session:(Session.Id.of_string "session-1")
         ~objective:"Make the suite green." ?token_budget ~created_at:(time 10)
         ())

  let goal_rejections () =
    is_error "empty goal id" (Goal.Id.of_string "");
    is_error "empty objective"
      (Goal.set
         ~id:(ok "id" (Goal.Id.of_string "g"))
         ~session:(Session.Id.of_string "s") ~objective:"" ~created_at:(time 1)
         ());
    is_error "zero budget"
      (Goal.set
         ~id:(ok "id" (Goal.Id.of_string "g"))
         ~session:(Session.Id.of_string "s") ~objective:"Do." ~token_budget:0
         ~created_at:(time 1) ())

  let goal_transitions () =
    let goal = a_goal () in
    is_true ~msg:"fresh goal is active and unfinished"
      (Goal.is_active goal && Goal.is_unfinished goal && Goal.may_update goal);
    let paused = ok "pause" (Goal.pause ~paused_at:(time 20) goal) in
    is_true ~msg:"paused goal may not update" (not (Goal.may_update paused));
    is_error "cannot resume before the previous transition"
      (Goal.resume ~resumed_at:(time 15) paused);
    is_error "cannot pause a paused goal"
      (Goal.pause ~paused_at:(time 30) paused);
    is_error "cannot pause before creation"
      (Goal.pause ~paused_at:(time 5) goal);
    let resumed =
      ok "resume" (Goal.resume ~resumed_at:(time 30) ~token_budget:100 paused)
    in
    is_true ~msg:"resume reactivates and replaces the budget"
      (Goal.is_active resumed && Goal.token_budget resumed = Some 100);
    let edited =
      ok "edit" (Goal.edit ~objective:"Do more." ~edited_at:(time 35) paused)
    in
    is_true ~msg:"edit keeps the status"
      (String.equal (Goal.Status.to_string (Goal.status edited)) "paused"
      && String.equal (Goal.objective edited) "Do more.");
    let blocked =
      ok "block" (Goal.block ~blocked_at:(time 40) ~reason:"stuck" goal)
    in
    is_error "empty block reason"
      (Goal.block ~blocked_at:(time 40) ~reason:"" goal);
    is_true ~msg:"blocked goal resumes"
      (Result.is_ok (Goal.resume ~resumed_at:(time 50) blocked));
    let completed =
      ok "complete" (Goal.complete ~completed_at:(time 60) ~summary:"done" goal)
    in
    is_true ~msg:"completed goal is terminal"
      (not (Goal.is_unfinished completed));
    is_error "cannot resume a completed goal"
      (Goal.resume ~resumed_at:(time 70) completed);
    is_error "cannot clear a completed goal"
      (Goal.clear ~cleared_at:(time 70) completed);
    is_error "cannot complete a paused goal"
      (Goal.complete ~completed_at:(time 70) paused);
    let cleared = ok "clear" (Goal.clear ~cleared_at:(time 20) goal) in
    is_true ~msg:"cleared goal is terminal" (not (Goal.is_unfinished cleared))

  let goal_budget_and_accounting () =
    let goal = a_goal ~token_budget:100 () in
    equal (option int) ~msg:"fresh budget remains whole" (Some 100)
      (Goal.remaining_tokens goal);
    let accrued =
      ok "record"
        (Goal.record_turn ~at:(time 20) ~tokens:60 ~active_ms:500
           ~continuation:false goal)
    in
    let accrued =
      ok "record continuation"
        (Goal.record_turn ~at:(time 30) ~tokens:60 ~active_ms:250
           ~continuation:true accrued)
    in
    equal int ~msg:"tokens accrue" 120 (Goal.tokens_used accrued);
    equal int ~msg:"time accrues" 750 (Goal.time_used_ms accrued);
    equal int ~msg:"continuations count" 1 (Goal.continuation_turns accrued);
    equal (option int) ~msg:"remaining floors at zero" (Some 0)
      (Goal.remaining_tokens accrued);
    is_error "negative tokens"
      (Goal.record_turn ~at:(time 40) ~tokens:(-1) ~active_ms:0
         ~continuation:false accrued);
    let limited =
      ok "limit" (Goal.limit_budget ~limited_at:(time 40) accrued)
    in
    is_true ~msg:"budget-limited goal still accepts updates"
      (Goal.may_update limited);
    is_true ~msg:"budget-limited goal still accrues"
      (Result.is_ok
         (Goal.record_turn ~at:(time 50) ~tokens:1 ~active_ms:1
            ~continuation:false limited));
    is_error "cannot budget-limit an unbudgeted goal"
      (Goal.limit_budget ~limited_at:(time 20) (a_goal ()));
    is_true ~msg:"budget-limited goal completes with usage report"
      (Result.is_ok (Goal.complete ~completed_at:(time 60) limited))

  let goal_budget_limit_requires_exhaustion () =
    is_error "cannot budget-limit while budget remains"
      (Goal.limit_budget ~limited_at:(time 20) (a_goal ~token_budget:100 ()));
    let json ?token_budget tokens_used =
      let budget =
        match token_budget with
        | None -> ""
        | Some budget -> Printf.sprintf ",\"token_budget\":%d" budget
      in
      Printf.sprintf
        {|{"id":"goal-1","session":"session-1","objective":"Do it","status":{"type":"budget_limited"}%s,"tokens_used":%d,"time_used_ms":0,"continuation_turns":0,"created_at":10,"updated_at":20}|}
        budget tokens_used
    in
    let rejects message json =
      match Jsont_bytesrw.decode_string Goal.jsont json with
      | Error _ -> ()
      | Ok _ -> failf "%s" message
    in
    rejects "budget-limited goal without a budget should be rejected" (json 0);
    rejects "budget-limited goal with remaining budget should be rejected"
      (json ~token_budget:100 99);
    match
      Jsont_bytesrw.decode_string Goal.jsont (json ~token_budget:100 100)
    with
    | Ok _ -> ()
    | Error error ->
        failf "exhausted budget-limited goal should decode: %s" error

  let goal_round_trips () =
    round_trip ~msg:"goal jsont round-trips" ~equal:Goal.equal Goal.jsont
      (ok "block"
         (Goal.block ~blocked_at:(time 40) ~reason:"stuck"
            (ok "record"
               (Goal.record_turn ~at:(time 20) ~tokens:60 ~active_ms:500
                  ~continuation:true
                  (a_goal ~token_budget:100 ())))));
    round_trip ~msg:"fresh goal round-trips" ~equal:Goal.equal Goal.jsont
      (a_goal ())

  let goal_update_and_apply () =
    let update =
      ok "update" (Goal.Update.make ~status:"complete" ~summary:"done" ())
    in
    is_error "unknown update status" (Goal.Update.make ~status:"paused" ());
    is_error "empty update summary"
      (Goal.Update.make ~status:"blocked" ~summary:"" ());
    let goal = a_goal () in
    let completed = ok "apply" (Goal.apply ~now:(time 20) update goal) in
    is_true ~msg:"apply complete carries the summary"
      (match Goal.status completed with
      | Goal.Status.Completed { summary = Some "done" } -> true
      | _ -> false);
    let paused = ok "pause" (Goal.pause ~paused_at:(time 20) goal) in
    is_error "apply refuses a paused goal"
      (Goal.apply ~now:(time 30) update paused);
    is_true ~msg:"update_goal decode error is prose"
      (match
         Goal.decode
           (call ~name:"update_goal" ~input:(obj [ ("status", str "paused") ]))
       with
      | Error e -> not (String.is_empty e)
      | Ok _ -> false);
    is_error "wrong tool name is rejected"
      (Goal.decode (call ~name:"read_file" ~input:(obj [])))

  let goal_turn_origin () =
    let turn ?origin () =
      Session.Turn.make
        ~id:(Session.Turn.Id.of_string "turn-1")
        ~input:(Session.Turn.Input.user_text "hi")
        ~model:
          (Llm.Model.make
             ~provider:(Llm.Provider.make "openai")
             ~api:(Llm.Model.Api.make "responses")
             ~id:"gpt-5")
        ?origin ()
    in
    is_true ~msg:"goal origin marks a continuation turn"
      (Goal.is_continuation_turn (turn ~origin:Goal.turn_origin ()));
    is_true ~msg:"absent origin is a user turn"
      (not (Goal.is_continuation_turn (turn ())));
    is_true ~msg:"unknown origin degrades to a user turn"
      (not (Goal.is_continuation_turn (turn ~origin:"nonsense" ())))

  (* Question *)

  let question_cases () =
    is_error "empty question" (Question.Request.make ~question:"" ());
    let request = ok "question" (Question.Request.make ~question:"Why?" ()) in
    round_trip ~msg:"question jsont round-trips" ~equal:Question.Request.equal
      Question.Request.jsont request;
    (* Structured options round-trip and a bare question stays free-text. *)
    is_error "empty option label" (Question.Option.make ~label:"" ());
    let opt label = ok "option" (Question.Option.make ~label ()) in
    let structured =
      ok "structured"
        (Question.Request.make ~header:"Pick one" ~question:"Which runner?"
           ~options:[ opt "dune"; opt "alcotest" ]
           ~multi:true ())
    in
    round_trip ~msg:"structured question round-trips"
      ~equal:Question.Request.equal Question.Request.jsont structured;
    is_true ~msg:"bare question has no options"
      (Question.Request.options request = []
      && not (Question.Request.multi request));
    is_true ~msg:"structured question keeps its options"
      (List.length (Question.Request.options structured) = 2
      && Question.Request.multi structured
      && Question.Request.header structured = Some "Pick one");
    is_error "empty answer text" (Question.answer_text "");
    is_true ~msg:"answer text wraps the answer"
      (match Question.answer_text "yes" with
      | Ok s -> not (String.is_empty s)
      | Error _ -> false);
    is_true ~msg:"ask_user decode error is prose"
      (match
         Question.decode
           (call ~name:"ask_user" ~input:(obj [ ("question", str "") ]))
       with
      | Error e -> not (String.is_empty e)
      | Ok _ -> false)

  let suite =
    group "artifacts"
      [
        test "plan rejections" plan_rejections;
        test "plan transitions" plan_transitions;
        test "plan round-trips" plan_round_trips;
        test "plan decode rejects self-supersession"
          plan_decode_rejects_self_supersession;
        test "plan decode prose" plan_decode_prose;
        test "plan decision" plan_decision;
        test "todo rejections" todo_rejections;
        test "todo round-trips" todo_round_trips;
        test "todo decode prose" todo_decode_prose;
        test "subagent rejections" subagent_rejections;
        test "subagent round-trips" subagent_round_trips;
        test "subagent decode prose" subagent_decode_prose;
        test "subagent run rejections" run_rejections;
        test "subagent run transitions" run_transitions;
        test "subagent run round-trips" run_round_trips;
        test "subagent run cancel" run_cancel;
        test "subagent run usage round-trips" run_usage_round_trips;
        test "subagent run usage rejects negative counts" run_usage_rejections;
        test "subagent run legacy decode" run_legacy_decode;
        test "goal rejections" goal_rejections;
        test "goal transitions" goal_transitions;
        test "goal budget and accounting" goal_budget_and_accounting;
        test "goal budget limit requires exhaustion"
          goal_budget_limit_requires_exhaustion;
        test "goal round-trips" goal_round_trips;
        test "goal update and apply" goal_update_and_apply;
        test "goal turn origin" goal_turn_origin;
        test "question cases" question_cases;
      ]
end

(* Command, Outcome, Error. *)
module Boundary_tests = struct
  module Command = Spice_protocol.Command
  module Outcome = Spice_protocol.Outcome
  module Error = Spice_protocol.Error
  module Session = Spice_session
  module Llm = Spice_llm
  module Tool = Spice_tool
  module Permission = Spice_permission

  let turn_id = Session.Turn.Id.of_string "turn-1"

  let start =
    Command.Start.make ~id:turn_id
      ~input:(Session.Turn.Input.user_text "Go.") ()

  let ask_call =
    Llm.Tool.Call.make ~id:"call-1" ~name:"ask_user"
      ~input:(obj [ ("question", str "Why?") ])
      ()

  let session_id = Session.Id.of_string "session-1"
  let permission_id = Session.Permission.Id.of_string "perm-1"
  let tool_claim_id = Session.Tool_claim.Id.of_string "claim-1"

  let all_errors : Error.t list =
    [
      Error.Conflict
        {
          id = session_id;
          expected = Session.Revision.of_string "r1";
          actual = Session.Revision.of_string "r2";
        };
      Error.Not_found session_id;
      Error.Storage { path = "/store/x"; message = "corrupt" };
      Error.Provider
        (Llm.Error.make ~kind:Llm.Error.Auth "authentication failed");
      Error.Invalid_answer "answer must not be empty";
      Error.Archived session_id;
      Error.Deleted session_id;
      Error.Active_turn_exists turn_id;
      Error.No_active_turn;
      Error.Permission_not_pending permission_id;
      Error.Tool_claim_not_pending tool_claim_id;
      Error.Tool_call_not_pending { call_id = "call-1"; name = "ask_user" };
      Error.Transcript_not_ready
        (Llm.Transcript.Error.Unknown_tool_result { call_id = "call-9" });
      Error.Nothing_to_summarize;
      Error.No_compaction_model;
      Error.Empty_compaction_summary;
      Error.Internal "invariant violated";
    ]

  let error_messages_are_non_empty () =
    List.iter
      (fun error ->
        is_true
          ~msg:("message is non-empty: " ^ Format.asprintf "%a" Error.pp error)
          (not (String.is_empty (Error.message error)));
        (* diagnostic must render without raising *)
        ignore (Error.diagnostic error))
      all_errors

  let non_empty_pp ~msg pp value =
    is_true ~msg (not (String.is_empty (Format.asprintf "%a" pp value)))

  let command_pp_smoke () =
    let result =
      Tool.Result.completed ~output:(Tool.Output.make ~text:"ok" ()) ()
    in
    let commands =
      [
        Command.Start start;
        Command.Resume;
        Command.Reply
          {
            permission = permission_id;
            answer = Permission.Policy.Review.(Allow Once);
            via = Some `Reviewer;
            message = Some "denied";
          };
        Command.Reply
          {
            permission = permission_id;
            answer = Permission.Policy.Review.Deny;
            via = None;
            message = None;
          };
        Command.Answer { turn = turn_id; call_id = "call-1"; answer = "yes" };
        Command.Finish_tool (tool_claim_id, result);
        Command.Interrupt { reason = Some "user cancelled" };
      ]
    in
    List.iter (non_empty_pp ~msg:"command pp is non-empty" Command.pp) commands

  let outcome_waiting_and_finished () =
    let waiting = Session.Waiting.host_tool ~turn:turn_id ask_call in
    let blocked = Outcome.of_waiting waiting in
    let finished =
      Outcome.finished ~turn:turn_id ~outcome:Session.Turn.Outcome.completed
    in
    is_true ~msg:"waiting outcome exposes its waiting"
      (Option.is_some (Outcome.waiting blocked));
    equal (option string) ~msg:"finished outcome has no waiting" None
      (Option.map (fun _ -> "w") (Outcome.waiting finished));
    non_empty_pp ~msg:"waiting pp is non-empty" Outcome.pp blocked;
    non_empty_pp ~msg:"finished pp is non-empty" Outcome.pp finished

  module Pending = Spice_protocol.Pending

  let plan_call =
    Llm.Tool.Call.make ~id:"call-9" ~name:"propose_plan"
      ~input:(obj [ ("id", str "plan-1"); ("body", str "Do the thing.") ])
      ()

  let todo_call =
    Llm.Tool.Call.make ~id:"call-7" ~name:"todo_write"
      ~input:(obj [ ("todos", Jsont.Json.list []) ])
      ()

  (* [of_outcome] is defined over Outcome's pre-applied [call]: a question, a
     plan, and any other host tool project to distinct arms, and a finished
     outcome to [None]. *)
  let pending_of_outcome () =
    let of_call call =
      let waiting = Session.Waiting.host_tool ~turn:turn_id call in
      Pending.of_outcome (Outcome.of_waiting waiting)
    in
    (match of_call ask_call with
    | Some (Pending.Question { turn; call_id; _ }) ->
        is_true ~msg:"question carries its turn"
          (Session.Turn.Id.equal turn turn_id);
        equal string ~msg:"question carries its call id" "call-1" call_id
    | _ -> failf "ask_user did not project to a Question boundary");
    (match of_call plan_call with
    | Some (Pending.Plan { call_id; _ }) ->
        equal string ~msg:"plan carries its call id" "call-9" call_id
    | _ -> failf "propose_plan did not project to a Plan boundary");
    (match of_call todo_call with
    | Some (Pending.Host_tool { call_id; _ }) ->
        equal string ~msg:"todo falls through to Host_tool" "call-7" call_id
    | _ -> failf "todo_write did not project to a Host_tool boundary");
    is_true ~msg:"finished outcome has no pending boundary"
      (Option.is_none
         (Pending.of_outcome
            (Outcome.finished ~turn:turn_id
               ~outcome:Session.Turn.Outcome.completed)))

  let suite =
    group "boundary"
      [
        test "error messages are non-empty" error_messages_are_non_empty;
        test "command pp smoke" command_pp_smoke;
        test "outcome waiting and finished" outcome_waiting_and_finished;
        test "pending of_outcome projects each boundary" pending_of_outcome;
      ]
end

(* Session summary projection. *)
module Summary_tests = struct
  module Summary = Spice_protocol.Session_summary
  module Session = Spice_session
  module Llm = Spice_llm

  let model =
    Llm.Model.make
      ~provider:(Llm.Provider.make "openai")
      ~api:(Llm.Model.Api.make "responses")
      ~id:"gpt-5"

  let cwd = Spice_path.Abs.of_string_exn "/home/work/project"

  let session_with_turn () =
    let session =
      Session.create
        ~id:(Session.Id.of_string "session-1")
        ~cwd
        ~created_at:(Session.Time.of_unix_ms 1L)
        ()
    in
    let turn =
      Session.Turn.make
        ~id:(Session.Turn.Id.of_string "turn-1")
        ~input:
          (Session.Turn.Input.user_text "Refactor    the\n  parser please.")
        ~model ()
    in
    match Session.Log.append (Session.Event.turn_started turn) session with
    | Ok session -> session
    | Error error -> failf "turn start failed: %a" Session.Error.pp error

  let projection_and_preview () =
    let summary = Summary.of_session (session_with_turn ()) in
    equal (option string) ~msg:"first user prompt is the normalized preview"
      (Some "Refactor the parser please.") summary.Summary.preview;
    equal (option string) ~msg:"revision is None for synthetic rows" None
      (Option.map Session.Revision.to_string summary.Summary.revision);
    equal int ~msg:"event count reflects the log" 1 summary.Summary.event_count;
    equal int ~msg:"started active turn counts as a turn" 1 summary.Summary.turns

  let revision_is_carried () =
    let summary =
      Summary.of_session
        ~revision:(Session.Revision.of_string "rev-7")
        (session_with_turn ())
    in
    equal (option string) ~msg:"revision is carried" (Some "rev-7")
      (Option.map Session.Revision.to_string summary.Summary.revision)

  let display_title_falls_back_to_id () =
    let summary = Summary.of_session (session_with_turn ()) in
    equal string ~msg:"an untitled session displays its id" "session-1"
      (Summary.display_title summary);
    let titled =
      Summary.of_session
        (Session.set_title (Some "My session") (session_with_turn ()))
    in
    equal string ~msg:"a titled session displays its title" "My session"
      (Summary.display_title titled)

  let contains haystack needle =
    let hn = String.length haystack and nn = String.length needle in
    let rec loop i =
      if i + nn > hn then false
      else if String.equal (String.sub haystack i nn) needle then true
      else loop (i + 1)
    in
    loop 0

  let search_key_includes_identity_and_cwd () =
    let key = Summary.search_key (Summary.of_session (session_with_turn ())) in
    let contains needle = contains key needle in
    is_true ~msg:"search key includes the id" (contains "session-1");
    is_true ~msg:"search key includes the cwd" (contains "/home/work/project");
    is_true ~msg:"search key includes the preview" (contains "parser")

  let suite =
    group "summary"
      [
        test "projection and preview" projection_and_preview;
        test "revision is carried" revision_is_carried;
        test "display_title falls back to id" display_title_falls_back_to_id;
        test "search_key includes identity and cwd"
          search_key_includes_identity_and_cwd;
      ]
end

(* The egress event language. *)
module Event_tests = struct
  module Event = Spice_protocol.Event
  module Call = Spice_protocol.Call
  module Session = Spice_session
  module Llm = Spice_llm
  module Permission = Spice_permission

  let model =
    Llm.Model.make
      ~provider:(Llm.Provider.make "openai")
      ~api:(Llm.Model.Api.make "responses")
      ~id:"gpt-5"

  let cwd = Spice_path.Abs.of_string_exn "/workspace"
  let time ms = Session.Time.of_unix_ms (Int64.of_int ms)
  let turn_id id = Session.Turn.Id.of_string id
  let question_input = obj [ ("question", str "Why?") ]

  let turn ?(id = "turn-1") ?(host_tools = [ "ask_user" ]) ?(text = "Question?")
      () =
    Session.Turn.make ~id:(turn_id id)
      ~input:(Session.Turn.Input.user_text text)
      ~model ~host_tools ()

  let response assistant = Llm.Response.make ~model assistant
  let call ~id ~name ~input = Llm.Tool.Call.make ~id ~name ~input ()

  let assistant_call c =
    Llm.Message.Assistant.make [ Llm.Message.Assistant.tool_call c ]

  let answer c text = Llm.Message.tool_result (Llm.Tool.Result.text c text)

  let transcript messages =
    match Llm.Transcript.of_list messages with
    | Ok transcript -> transcript
    | Error error -> failf "transcript failed: %a" Llm.Transcript.Error.pp error

  let extension_access name = Permission.Access.custom ~kind:`Custom name

  let permission_request ~turn ~tool_call access =
    let request = Permission.Request.of_accesses [ access ] in
    let access_set = Permission.Access.Set.singleton access in
    let ask =
      match Permission.Policy.Review.restore request access_set with
      | Ok ask -> ask
      | Error _ -> failf "permission review reconstruction failed"
    in
    Session.Permission.Requested.of_review
      ~id:(Session.Permission.Id.of_string "perm-1")
      ~turn ~tool_call ask

  let q_call = call ~id:"call-q" ~name:"ask_user" ~input:question_input
  let q2_call = call ~id:"call-q2" ~name:"ask_user" ~input:question_input
  let read_call = call ~id:"call-x" ~name:"read_file" ~input:(obj [])

  (* A well-ordered lifecycle covering a resolved host call, a compaction, a
     permission request/resolve pair, and a still-pending host call. *)
  let golden_session () =
    let events =
      [
        (* Turn 1: a host-tool call answered, then a final assistant text. *)
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response (assistant_call q_call));
        Session.Event.message_appended (answer q_call "Answered.");
        Session.Event.response_appended
          (response (Llm.Message.Assistant.text "Final answer."));
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
        (* A durable compaction is installed between turns. *)
        Session.Event.compaction_installed
          (Session.Compaction.make
             ~reason:Session.Compaction.Reason.User_requested
             ~summary:"Summary of turn 1."
             ~transcript:
               (transcript [ Llm.Message.user_text "Summary of turn 1." ])
             ());
        (* Turn 2: an executable tool call gated by a permission, then a
           still-pending host-tool call at the boundary. *)
        Session.Event.turn_started (turn ~id:"turn-2" ~text:"More." ());
        Session.Event.response_appended (response (assistant_call read_call));
        Session.Event.permission_requested
          (permission_request ~turn:(turn_id "turn-2") ~tool_call:read_call
             (extension_access "read_file"));
        Session.Event.permission_resolved
          (Session.Permission.Resolved.allow_session
             ~id:(Session.Permission.Id.of_string "perm-1"));
        Session.Event.message_appended (answer read_call "file contents");
        Session.Event.response_appended (response (assistant_call q2_call));
      ]
    in
    let session =
      Session.create
        ~id:(Session.Id.of_string "session-1")
        ~cwd ~created_at:(time 1) ()
    in
    let rec append i session = function
      | [] -> session
      | event :: rest -> (
          match Session.Log.append event session with
          | Ok session -> append (i + 1) session rest
          | Error error ->
              failf "append of event %d failed: %a" i Session.Error.pp error)
    in
    append 0 session events

  let host_calls events =
    List.filter_map
      (function
        | Event.Host_call { call; result; _ } ->
            Some (Llm.Tool.Call.id call, Option.is_some result)
        | _ -> None)
      events

  let count pred events = List.length (List.filter pred events)

  let of_session_projection () =
    let events = Event.of_session (golden_session ()) in
    is_true ~msg:"of_session yields only durable events"
      (List.for_all Event.is_durable events);
    equal
      (list (pair string bool))
      ~msg:"one resolved and one pending host call, correlated by id"
      [ ("call-q", true); ("call-q2", false) ]
      (host_calls events);
    let final_texts =
      List.filter_map
        (function
          | Event.Turn_finished { final_text; _ } -> Some final_text | _ -> None)
        events
    in
    equal
      (list (option string))
      ~msg:"finished turn carries final text" [ Some "Final answer." ]
      final_texts;
    equal int ~msg:"one permission requested" 1
      (count
         (function Event.Permission_requested _ -> true | _ -> false)
         events);
    equal int ~msg:"one permission resolved" 1
      (count
         (function Event.Permission_resolved _ -> true | _ -> false)
         events);
    equal int ~msg:"one compaction installed" 1
      (count (function Event.Compaction _ -> true | _ -> false) events)

  let host_call_kind_is_classified () =
    let events = Event.of_session (golden_session ()) in
    is_true ~msg:"the resolved host call is classified as a question"
      (List.exists
         (function
           | Event.Host_call { kind = Some (Call.Question _); _ } -> true
           | _ -> false)
         events)

  let host_tool_recognition_is_turn_local () =
    let extension_call =
      call ~id:"call-extension" ~name:"extension_call" ~input:(obj [])
    in
    let events =
      [
        Session.Event.turn_started
          (turn ~id:"turn-1" ~host_tools:[ "extension_call" ] ());
        Session.Event.turn_finished ~turn:(turn_id "turn-1")
          Session.Turn.Outcome.completed;
        Session.Event.turn_started (turn ~id:"turn-2" ~host_tools:[] ());
        Session.Event.response_appended
          (response (assistant_call extension_call));
      ]
    in
    let session =
      Session.create
        ~id:(Session.Id.of_string "session-turn-local")
        ~cwd ~created_at:(time 1) ()
    in
    let session =
      List.fold_left
        (fun session event ->
          match Session.Log.append event session with
          | Ok session -> session
          | Error error ->
              failf "turn-local event append failed: %a" Session.Error.pp error)
        session events
    in
    equal
      (list (pair string bool))
      ~msg:"a prior turn's host tools do not classify a later turn's calls" []
      (host_calls (Event.of_session session))

  let replay_degrades_tool_failure_status () =
    let execution =
      Session.Tool_claim.Started.make
        ~id:(Session.Tool_claim.Id.of_string "claim-failed")
        ~turn:(turn_id "turn-1") ~call:read_call
    in
    let finished =
      Session.Tool_claim.Finished.make
        ~id:(Session.Tool_claim.Started.id execution)
        ~output:(Some (Spice_tool.Output.make ~text:"partial evidence" ()))
        (Llm.Tool.Result.text ~error:true read_call "cancelled upstream")
    in
    let session =
      Session.create
        ~id:(Session.Id.of_string "session-tool-failure")
        ~cwd ~created_at:(time 1) ()
    in
    let events =
      [
        Session.Event.turn_started (turn ~host_tools:[] ());
        Session.Event.response_appended (response (assistant_call read_call));
        Session.Event.tool_claim_started execution;
        Session.Event.tool_claim_finished finished;
      ]
    in
    let session =
      List.fold_left
        (fun session event ->
          match Session.Log.append event session with
          | Ok session -> session
          | Error error ->
              failf "tool-failure event append failed: %a" Session.Error.pp
                error)
        session events
    in
    match
      List.find_map
        (function Event.Tool_finished { result; _ } -> Some result | _ -> None)
        (Event.of_session session)
    with
    | None -> failf "replay omitted the finished tool"
    | Some result ->
        (match Spice_tool.Result.status result with
        | Spice_tool.Result.Failed
            { kind = `Failed; message = "cancelled upstream"; metadata = None }
          ->
            ()
        | Spice_tool.Result.Completed ->
            failf "replayed error became completed"
        | Spice_tool.Result.Interrupted _ ->
            failf "replay unexpectedly preserved interrupted status"
        | Spice_tool.Result.Failed { kind; message; _ } ->
            failf "replayed failure was %s: %s"
              (Spice_tool.Result.failure_to_string kind)
              message);
        equal (option string) ~msg:"replay retains stored erased output"
          (Some "partial evidence")
          (Option.map Spice_tool.Output.text (Spice_tool.Result.output result))

  let live_only_events_are_not_durable () =
    let request =
      match
        Llm.Request.make ~model (transcript [ Llm.Message.user_text "hi" ])
      with
      | Ok request -> request
      | Error error -> failf "request failed: %a" Llm.Request.Error.pp error
    in
    let live : Event.t list =
      [
        Event.Assistant_delta { text = "strea" };
        Event.Reasoning_delta { text = "think" };
        Event.Usage_updated (Llm.Usage.make ~input:3 ~output:1 ());
        Event.Model_started request;
        Event.Notices_injected [];
        Event.Workspace_degraded { message = "lost evidence" };
        Event.Compaction_progress (Event.Retrying { dropped_messages = 3 });
      ]
    in
    is_true ~msg:"live-only events are never durable"
      (List.for_all (fun e -> not (Event.is_durable e)) live)

  let suite =
    group "event"
      [
        test "of_session projection" of_session_projection;
        test "host call kind is classified" host_call_kind_is_classified;
        test "host tool recognition is turn-local"
          host_tool_recognition_is_turn_local;
        test "replay degrades tool failure status"
          replay_degrades_tool_failure_status;
        test "live-only events are not durable" live_only_events_are_not_durable;
      ]
end

(* Model artifact vocabulary. *)
module Model_artifact_tests = struct
  module Artifact = Spice_protocol.Model_artifact

  let status_summaries () =
    equal string ~msg:"installed names the path" "installed: /w/model.gguf"
      (Artifact.summary (Artifact.Installed { path = "/w/model.gguf" }));
    equal string ~msg:"missing with a known size renders it"
      "missing - auto-download 1.5 GB"
      (Artifact.summary
         (Artifact.Missing
            {
              path = "/w/model.gguf";
              size = Some 1_500_000_000L;
              source = None;
            }));
    equal string ~msg:"unavailable carries the diagnostic"
      "unavailable: no metadata"
      (Artifact.summary (Artifact.Unavailable { message = "no metadata" }))

  let download_outcomes () =
    let describe = function
      | Artifact.Already_installed path -> "installed:" ^ path
      | Artifact.Not_downloadable -> "explicit"
      | Artifact.Downloaded -> "downloaded"
      | Artifact.Refused { message; force_hint } ->
          Printf.sprintf "refused:%s:%b" message force_hint
    in
    equal string ~msg:"already installed keeps the path" "installed:/w.gguf"
      (describe (Artifact.Already_installed "/w.gguf"));
    equal string ~msg:"refusal carries message and force hint"
      "refused:over budget:true"
      (describe
         (Artifact.Refused { message = "over budget"; force_hint = true }))

  let suite =
    group "model artifact"
      [
        test "status summaries" status_summaries;
        test "download outcomes" download_outcomes;
      ]
end

let () =
  run "spice.protocol"
    [
      Call_tests.suite;
      Mode_tests.suite;
      Contract_tests.suite;
      Artifacts_tests.suite;
      Boundary_tests.suite;
      Summary_tests.suite;
      Model_artifact_tests.suite;
      Event_tests.suite;
    ]
