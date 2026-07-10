(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Spice_session

module Llm = Spice_llm
module Tool = Spice_tool

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as e -> e

module Error = struct
  type t =
    | Request of Llm.Request.Error.t
    | Tool of Tool.Error.t
    | No_active_turn
    | Permission_not_pending of Permission.Id.t
    | Tool_claim_not_pending of Tool_claim.Id.t
    | Tool_call_not_pending of { call_id : string; name : string }
    | Tool_result_mismatch of {
        expected_call_id : string;
        expected_name : string;
        actual_call_id : string;
        actual_name : string;
      }
    | Archived
    | Deleted
    | State of State.Error.t

  let message = function
    | Request error -> Llm.Request.Error.message error
    | Tool error -> Tool.Error.message error
    | No_active_turn -> "session has no active turn"
    | Permission_not_pending id ->
        Format.asprintf "permission is not pending: %a" Permission.Id.pp id
    | Tool_claim_not_pending id ->
        Format.asprintf "tool claim is not pending: %a" Tool_claim.Id.pp id
    | Tool_call_not_pending { call_id; name } ->
        Printf.sprintf "tool call is not pending: %s (%s)" call_id name
    | Tool_result_mismatch
        { expected_call_id; expected_name; actual_call_id; actual_name } ->
        Printf.sprintf "host tool result mismatch: expected %s/%s, got %s/%s"
          expected_call_id expected_name actual_call_id actual_name
    | Archived -> "session is archived"
    | Deleted -> "session has been deleted"
    | State error -> State.Error.message error

  let pp ppf error = Format.pp_print_string ppf (message error)
end

let of_append_error = function
  | Spice_session.Error.State error -> Error.State error
  | Spice_session.Error.Replay error ->
      Error.State (State.Replay_error.cause error)
  | Spice_session.Error.Archived -> Error.Archived
  | Spice_session.Error.Deleted -> Error.Deleted
  (* [Log.append] guards only active lifecycle and [State.apply], so it
     never yields these; only [archive]/[delete]/[fork]/[rewind] and anchor
     resolution do. *)
  | Spice_session.Error.Active_turn _ | Spice_session.Error.Unknown_turn _
  | Spice_session.Error.Turn_not_finished _ ->
      assert false

let require_active_session session =
  match Metadata.status (metadata session) with
  | Metadata.Status.Active -> Ok ()
  | Metadata.Status.Archived -> Error Error.Archived
  | Metadata.Status.Deleted -> Error Error.Deleted

module Config = struct
  type t = {
    tools : Tool.Catalog.t;
    host_tool_names : string list;
    policy : Spice_permission.Policy.t;
    prelude : Llm.Request.Prelude.t;
    safety_step_cap : int;
    denial_message : Spice_permission.Policy.Denial.t -> string;
    declarations : Llm.Tool.t list;
  }

  let default_denial_message _ = "Permission denied by policy."

  let executable_declaration tool =
    Llm.Tool.make ~name:(Tool.name tool) ~description:(Tool.description tool)
      ~input_schema:(Tool.input_schema tool) ()

  let executable_declarations tools =
    try
      List.map executable_declaration (Tool.Catalog.tools tools)
    with Invalid_argument message ->
      invalid_arg
        ("Spice_session_run.Config.make: invalid executable tool \
          declaration: " ^ message)

  let invalid_config message =
    invalid_arg ("Spice_session_run.Config.make: " ^ message)

  let validate_host_tool_names tools host_tools =
    let executable_names = List.map Tool.name (Tool.Catalog.tools tools) in
    let rec loop seen = function
      | [] -> ()
      | host_tool :: host_tools ->
          let name = Llm.Tool.name host_tool in
          if List.exists (String.equal name) executable_names then
            invalid_config
              ("host tool name also used by executable tool: " ^ name)
          else if List.exists (String.equal name) seen then
            invalid_config ("duplicate host tool name: " ^ name)
          else loop (name :: seen) host_tools
    in
    loop [] host_tools

  let make ~tools ?(host_tools = []) ~policy
      ?(prelude = Llm.Request.Prelude.empty) ?(safety_step_cap = max_int)
      ?(denial_message = default_denial_message) () =
    if safety_step_cap <= 0 then
      invalid_config
        (Printf.sprintf "safety_step_cap must be positive, got %d"
           safety_step_cap);
    match Tool.Catalog.make tools with
    | Error error -> invalid_config (Tool.Error.message error)
    | Ok tools ->
      let executable_declarations = executable_declarations tools in
      validate_host_tool_names tools host_tools;
      let declarations = executable_declarations @ host_tools in
      let host_tool_names = List.map Llm.Tool.name host_tools in
      {
        tools;
        host_tool_names;
          policy;
          prelude;
          safety_step_cap;
          denial_message;
          declarations;
        }

  let declarations t = t.declarations
end

module Step = struct
  type next =
    | Request_model of Llm.Request.t
    | Run_tool of { claim : Tool_claim.Started.t; call : Tool.Call.t }
    | Waiting of Waiting.t
    | Finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }

  type nonrec t = { events : Event.t list; session : t; next : next }

  let pp_next ppf = function
    | Request_model _ -> Format.pp_print_string ppf "request-model"
    | Run_tool { claim; call = _ } ->
        Format.fprintf ppf "run-tool(%a)" Tool_claim.Started.pp claim
    | Waiting waiting -> Format.fprintf ppf "waiting %a" Waiting.pp waiting
    | Finished { turn; outcome } ->
        Format.fprintf ppf "finished %a %a" Turn.Id.pp turn Turn.Outcome.pp
          outcome

  let make ~session ~events ~next =
    match Log.append_all events session with
    | Error error -> Error (of_append_error error)
    | Ok session -> Ok { events; session; next }

  let of_applied ~events ~session ~next = { events; session; next }
  let events (t : t) = t.events
  let session t = t.session
  let next t = t.next
end

let active_turn session =
  let* () = require_active_session session in
  let state = state session in
  match State.active_turn state with
  | None -> Error Error.No_active_turn
  | Some turn -> Ok turn

let active_turn_id session =
  let* turn = active_turn session in
  Ok (Turn.id turn)

let request_for_turn config session turn =
  let state = state session in
  (* The session id is the stable prompt-cache routing key: one conversation,
     one cache shard, across every request of every turn. *)
  Llm.Request.make ~model:(Turn.model turn) ~prelude:config.Config.prelude
    ~tools:(Turn.declarations turn)
    ~options:(Turn.options turn)
    ~cache_key:(Id.to_string (id session))
    (State.transcript state)
  |> Result.map_error (fun error -> Error.Request error)

type decision =
  | Continue of Event.t
  | Boundary of Event.t list * Step.next

let finish turn outcome =
  let event = Event.turn_finished ~turn outcome in
  Boundary ([ event ], Step.Finished { turn; outcome })

let effective_step_limit config turn =
  min (Turn.max_steps turn) config.Config.safety_step_cap

let model_action config session turn_id turn =
  let state = state session in
  let response_count =
    match State.turn_response_count turn_id state with
    | Some count -> count
    | None -> 0
  in
  if response_count >= effective_step_limit config turn then
    Ok (finish turn_id Turn.Outcome.step_limit)
  else
    let* request = request_for_turn config session turn in
    Ok (Boundary ([], Step.Request_model request))

let tool_result_from_output call result =
  match (Tool.Result.status result, Tool.Result.output result) with
  | Tool.Result.Completed, Some output ->
      Llm.Tool.Result.text call (Tool.Output.text output)
  | Tool.Result.Completed, None -> Llm.Tool.Result.empty call
  | Tool.Result.Failed { message; _ }, Some output ->
      Llm.Tool.Result.text ~error:true call
        (message ^ "\n\n" ^ Tool.Output.text output)
  | Tool.Result.Failed { message; _ }, None ->
      Llm.Tool.Result.text ~error:true call message
  | Tool.Result.Interrupted { reason; _ }, Some output ->
      Llm.Tool.Result.text ~error:true call
        (reason ^ "\n\n" ^ Tool.Output.text output)
  | Tool.Result.Interrupted { reason; _ }, None ->
      Llm.Tool.Result.text ~error:true call reason

let tool_result_text ?(error = false) call text =
  if String.is_empty text then Llm.Tool.Result.empty ~error call
  else Llm.Tool.Result.text ~error call text

let interrupt ?reason session =
  let* turn = active_turn_id session in
  let outcome = Turn.Outcome.interrupted ?reason ~cancelled:true () in
  let st = state session in
  let reason_text = Option.value reason ~default:"interrupted" in
  let interrupted =
    Tool.Result.interrupted ~reason:reason_text ~cancelled:true ()
  in
  let pending_claims = State.pending_tool_claims st in
  let claim_for call =
    List.find_opt
      (fun execution ->
        String.equal
          (Llm.Tool.Call.id (Tool_claim.Started.call execution))
          (Llm.Tool.Call.id call))
      pending_claims
  in
  (* An interrupted turn may leave assistant tool calls unanswered — a settled
     host-tool question, or calls the drain had not reached. Each must carry a
     result or the next request is rejected for missing tool results. A
     planned-but-unrun executable claim is finished with the interrupted
     result (recording the claim outcome and its transcript message); a
     host-tool or not-yet-claimed call gets a direct interrupted tool result. *)
  let result_event call =
    match claim_for call with
    | Some execution ->
        Event.tool_claim_finished
          (Tool_claim.Finished.make
             ~id:(Tool_claim.Started.id execution)
             ~output:(Tool.Result.output interrupted)
             (tool_result_from_output call interrupted))
    | None ->
        Event.message_appended
          (Llm.Message.tool_result
             (tool_result_text ~error:true call reason_text))
  in
  let result_events =
    List.map result_event (Llm.Transcript.pending (State.transcript st))
  in
  Step.make ~session
    ~events:(result_events @ [ Event.turn_finished ~turn outcome ])
    ~next:(Step.Finished { turn; outcome })

let decode_tool tools call =
  Tool.Catalog.decode tools ~name:(Llm.Tool.Call.name call)
    ~input:(Llm.Tool.Call.input call) ()
  |> Result.map_error (fun error -> Error.Tool error)

let is_declared declarations call =
  List.exists
    (fun declaration ->
      String.equal (Llm.Tool.name declaration) (Llm.Tool.Call.name call))
    declarations

let permission_already_allows state call request review =
  let same_call requested =
    Llm.Tool.Call.equal (Permission.Requested.tool_call requested) call
  in
  let same_request requested =
    Spice_permission.Request.equal
      (Permission.Requested.request requested)
      request
  in
  let same_reviewed_accesses requested =
    Spice_permission.Access.Set.equal
      (Permission.Requested.asked requested)
      (Spice_permission.Policy.Review.access_set review)
  in
  let allows_reply resolved =
    match Permission.Resolved.decision resolved with
    | Permission.Resolved.Allow _ -> true
    | Permission.Resolved.Deny _ -> false
  in
  List.exists
    (fun (requested, resolved) ->
      same_call requested && same_request requested
      && same_reviewed_accesses requested
      &&
      match resolved with
      | Some reply -> allows_reply reply
      | None -> false)
    (State.permissions state)

let digest_id prefix ~domain fields =
  Permission.Id.of_string
    (prefix ^ ":" ^ Spice_digest.key ~length:16 ~domain fields)

let access_texts review =
  Spice_permission.Policy.Review.access_set review
  |> Spice_permission.Access.Set.elements
  |> List.map Spice_permission.Access.stable_text

let permission_request_text review =
  match
    Jsont.Json.encode Spice_permission.Request.jsont
      (Spice_permission.Policy.Review.request review)
  with
  | Ok json -> Format.asprintf "%a" Jsont.Json.pp json
  | Error message ->
      invalid_arg
        ("Spice_session_run.permission_id: permission request encode failed: "
       ^ message)

let permission_id turn_id call request_index review =
  digest_id "perm" ~domain:"spice.session.permission.v3"
    (Turn.Id.to_string turn_id :: Llm.Tool.Call.id call
    :: string_of_int request_index
    :: permission_request_text review :: access_texts review)

let tool_claim_id turn_id call =
  Tool_claim.Id.of_string
    ("tool_exec:"
    ^ Spice_digest.key ~length:16 ~domain:"spice.session.tool_claim.v1"
        [ Turn.Id.to_string turn_id; Llm.Tool.Call.id call ])

let request_permission turn_id call request_index review =
  let requested =
    Permission.Requested.of_review
      ~id:(permission_id turn_id call request_index review)
      ~turn:turn_id ~tool_call:call review
  in
  Boundary
    ( [ Event.permission_requested requested ],
      Step.Waiting (Waiting.Permission requested) )

let waiting_transition waiting = Boundary ([], Step.Waiting waiting)

let continue_tool_error call message =
  Continue
    (Event.message_appended
       (Llm.Message.tool_result
          (Llm.Tool.Result.text ~error:true call message)))

let review_tool_permissions config session turn_id call tool_call =
  let state = state session in
  let rec loop request_index = function
    | [] -> Ok `Allowed
    | request :: requests -> (
        match
          Spice_permission.Policy.decide ~grants:(State.grants state)
            config.Config.policy request
        with
        | Spice_permission.Policy.Decision.Allowed ->
            loop (request_index + 1) requests
        | Spice_permission.Policy.Decision.Denied (first, rest) ->
            Ok (`Denied (first, rest))
        | Spice_permission.Policy.Decision.Review review ->
            if permission_already_allows state call request review then
              loop (request_index + 1) requests
            else Ok (`Review (request_index, review)))
  in
  let* planning =
    match Tool.Call.permissions tool_call with
    | requests -> Ok (`Requests requests)
    | exception exn ->
        Ok
          (`Decision
            (continue_tool_error call
               ("tool permission planner raised: " ^ Printexc.to_string exn)))
  in
  match planning with
  | `Decision decision -> Ok (`Decision decision)
  | `Requests requests -> (
      let* decision = loop 0 requests in
      match decision with
      | `Allowed -> Ok `Allowed
      | `Denied denials ->
          let denial = fst denials in
          Ok
            (`Decision
              (continue_tool_error call (config.Config.denial_message denial)))
      | `Review (request_index, review) ->
          Ok
            (`Decision
              (request_permission turn_id call request_index review)))

let run_tool_action turn_id call tool_call =
  let execution =
    Tool_claim.Started.make
      ~id:(tool_claim_id turn_id call)
      ~turn:turn_id ~call
  in
  Boundary
    ( [ Event.tool_claim_started execution ],
      Step.Run_tool { claim = execution; call = tool_call } )

let tool_action config session turn_id turn call =
  if not (is_declared (Turn.declarations turn) call) then
    Ok
      (continue_tool_error call
         (Tool.Error.message
            (Tool.Error.Unknown_tool (Llm.Tool.Call.name call))))
  else
    match decode_tool config.Config.tools call with
    | Error (Error.Tool tool_error) ->
        Ok (continue_tool_error call (Tool.Error.message tool_error))
    | Error error -> Error error
    | Ok tool_call -> (
        let* permission =
          review_tool_permissions config session turn_id call tool_call
        in
        match permission with
        | `Decision decision -> Ok decision
        | `Allowed -> Ok (run_tool_action turn_id call tool_call))

let plan config session =
  let* turn = active_turn session in
  let turn_id = Turn.id turn in
  let state = state session in
  match State.waiting state with
  | Some waiting -> Ok (waiting_transition waiting)
  | None -> (
      match Llm.Transcript.state (State.transcript state) with
      | Llm.Transcript.Ready -> model_action config session turn_id turn
      | Llm.Transcript.Awaiting_tool_results (call, _) ->
          tool_action config session turn_id turn call)

let append_for_run events session =
  Log.append_all events session |> Result.map_error of_append_error

let normalize config session events =
  let rec loop session emitted events =
    match append_for_run events session with
    | Error error -> Error error
    | Ok session ->
        let emitted = List.rev_append events emitted in
        (match plan config session with
        | Error error -> Error error
        | Ok (Continue event) -> loop session emitted [ event ]
        | Ok (Boundary (events, next)) -> (
            match append_for_run events session with
            | Error error -> Error error
            | Ok session ->
                Ok
                  (Step.of_applied
                     ~events:(List.rev_append emitted events)
                     ~session ~next)))
  in
  loop session [] events

let resume config session = normalize config session []

let start config ~id ~input ~model ?options ?mode ?origin ?max_steps session =
  let* () = require_active_session session in
  let host_tools = config.Config.host_tool_names in
  let declarations = Config.declarations config in
  let safety_step_cap = config.Config.safety_step_cap in
  let max_steps =
    min (Option.value max_steps ~default:safety_step_cap) safety_step_cap
  in
  let turn =
    Turn.make ~id ~input ~model ?options ?mode ?origin ~max_steps ~declarations
      ~host_tools ()
  in
  normalize config session [ Event.turn_started turn ]

let accept_response config response session =
  let* turn_id = active_turn_id session in
  let response_event = Event.response_appended response in
  if Llm.Response.has_tool_calls response then
    normalize config session [ response_event ]
  else
    let outcome = Turn.Outcome.completed in
    let finish_event = Event.turn_finished ~turn:turn_id outcome in
    Step.make ~session
      ~events:[ response_event; finish_event ]
      ~next:(Step.Finished { turn = turn_id; outcome })

let finish_tool config id result session =
  let* () = require_active_session session in
  match State.pending_tool_claim id (state session) with
  | None -> Error (Error.Tool_claim_not_pending id)
  | Some saved ->
      let call = Tool_claim.Started.call saved in
      let finished =
        Tool_claim.Finished.make ~id ~output:(Tool.Result.output result)
          (tool_result_from_output call result)
      in
      normalize config session [ Event.tool_claim_finished finished ]

let resolve_permission config ?(message = "Permission denied.") ?via id answer
    session =
  let* () = require_active_session session in
  (* The product invariant is that unattended resolution can only deny; a
     host bug pairing unattended provenance with an allow must fail loudly
     rather than be laundered into a reviewer allow. The JSON decoder rejects
     the same state. *)
  (match (via, answer) with
  | Some `Unattended, Spice_permission.Policy.Review.Allow _ ->
      invalid_arg
        "Spice_session_run.resolve_permission: unattended provenance applies \
         only to denials"
  | (Some (`Unattended | `Reviewer) | None), _ -> ());
  match State.pending_permission id (state session) with
  | None -> Error (Error.Permission_not_pending id)
  | Some requested ->
      let resolved =
        match answer with
        | Spice_permission.Policy.Review.Allow
            Spice_permission.Policy.Review.Once ->
            Permission.Resolved.allow_once ~id
        | Spice_permission.Policy.Review.Allow
            Spice_permission.Policy.Review.Session ->
            Permission.Resolved.allow_session ~id
        | Spice_permission.Policy.Review.Deny ->
            let call = Permission.Requested.tool_call requested in
            Permission.Resolved.deny ~id ?via
              (tool_result_text ~error:true call message)
      in
      normalize config session [ Event.permission_resolved resolved ]

let pending_tool_call ~call_id ~name session =
  State.transcript (state session)
  |> Llm.Transcript.pending
  |> List.find_opt (fun call ->
      String.equal (Llm.Tool.Call.id call) call_id
      && String.equal (Llm.Tool.Call.name call) name)

let host_tool_matches_result waiting result =
  let call = waiting.Waiting.call in
  String.equal (Llm.Tool.Result.call_id result) (Llm.Tool.Call.id call)
  && String.equal (Llm.Tool.Result.name result) (Llm.Tool.Call.name call)

let answer_host_tool_result config waiting result session =
  let* () = require_active_session session in
  if not (host_tool_matches_result waiting result) then
    let call = waiting.Waiting.call in
    Error
      (Error.Tool_result_mismatch
         {
           expected_call_id = Llm.Tool.Call.id call;
           expected_name = Llm.Tool.Call.name call;
           actual_call_id = Llm.Tool.Result.call_id result;
           actual_name = Llm.Tool.Result.name result;
         })
  else
    let call_id = Llm.Tool.Result.call_id result in
    let name = Llm.Tool.Result.name result in
    match State.phase (state session) with
    | State.Phase.Waiting (Waiting.Host_tool current)
      when Waiting.equal (Waiting.Host_tool waiting)
             (Waiting.Host_tool current) -> (
        match pending_tool_call ~call_id ~name session with
        | None -> Error (Error.Tool_call_not_pending { call_id; name })
        | Some _ ->
            normalize config session
              [ Event.message_appended (Llm.Message.tool_result result) ])
    | State.Phase.Idle | State.Phase.Active | State.Phase.Waiting _ ->
        Error (Error.Tool_call_not_pending { call_id; name })

let answer_host_tool config ?(error = false) waiting ~text session =
  let call = waiting.Waiting.call in
  answer_host_tool_result config waiting
    (tool_result_text ~error call text)
    session
