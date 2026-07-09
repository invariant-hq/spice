(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Transcript = Spice_llm.Transcript
module Policy = Spice_permission.Policy
module Session_turn = Turn
module Session_permission = Permission
module Session_tool_claim = Tool_claim
module Turn_map = Map.Make (Turn.Id)
module Permission_map = Map.Make (Permission.Id)
module Tool_claim_map = Map.Make (Tool_claim.Id)

module Error = struct
  module Turn = struct
    type t =
      | Active of Session_turn.Id.t
      | No_active
      | Duplicate of Session_turn.Id.t
      | Unknown of Session_turn.Id.t
      | Finished of Session_turn.Id.t
      | Response_model_mismatch of {
          turn : Session_turn.Id.t;
          expected : Spice_llm.Model.t;
          actual : Spice_llm.Model.t;
        }
      | Unresolved_waiting of Session_turn.Id.t
  end

  module Permission = struct
    type t =
      | Duplicate of Session_permission.Id.t
      | Unknown of Session_permission.Id.t
      | Not_pending of Session_permission.Id.t
      | Tool_call_not_pending of {
          permission : Session_permission.Id.t;
          call_id : string;
        }
      | Result_mismatch of {
          permission : Session_permission.Id.t;
          expected_call_id : string;
          expected_name : string;
          actual_call_id : string;
          actual_name : string;
        }
  end

  module Tool_claim = struct
    type t =
      | Duplicate of Session_tool_claim.Id.t
      | Unknown of Session_tool_claim.Id.t
      | Not_pending of Session_tool_claim.Id.t
      | Tool_call_not_pending of {
          execution : Session_tool_claim.Id.t;
          call_id : string;
        }
      | Result_mismatch of {
          execution : Session_tool_claim.Id.t;
          expected_call_id : string;
          expected_name : string;
          actual_call_id : string;
          actual_name : string;
        }
  end

  type t =
    | Turn of Turn.t
    | Permission of Permission.t
    | Tool_claim of Tool_claim.t
    | Transcript of Transcript.Error.t

  let message = function
    | Turn (Turn.Active turn) ->
        Format.asprintf "turn is still active: %a" Session_turn.Id.pp turn
    | Turn Turn.No_active -> "no turn is active"
    | Turn (Turn.Duplicate turn) ->
        Format.asprintf "duplicate turn id: %a" Session_turn.Id.pp turn
    | Turn (Turn.Unknown turn) ->
        Format.asprintf "unknown turn: %a" Session_turn.Id.pp turn
    | Turn (Turn.Finished turn) ->
        Format.asprintf "turn has already finished: %a" Session_turn.Id.pp turn
    | Turn (Turn.Response_model_mismatch { turn; expected; actual }) ->
        Format.asprintf
          "response model does not match turn %a: expected %a, got %a"
          Session_turn.Id.pp turn Spice_llm.Model.pp expected Spice_llm.Model.pp
          actual
    | Permission (Permission.Duplicate id) ->
        Format.asprintf "duplicate permission request id: %a"
          Session_permission.Id.pp id
    | Permission (Permission.Unknown id) ->
        Format.asprintf "unknown permission request: %a"
          Session_permission.Id.pp id
    | Permission (Permission.Not_pending id) ->
        Format.asprintf "permission request is not pending: %a"
          Session_permission.Id.pp id
    | Permission (Permission.Tool_call_not_pending { permission; call_id }) ->
        Format.asprintf
          "permission request %a references non-pending tool call: %s"
          Session_permission.Id.pp permission call_id
    | Permission
        (Permission.Result_mismatch
           {
             permission;
             expected_call_id;
             expected_name;
             actual_call_id;
             actual_name;
           }) ->
        Format.asprintf
          "permission request %a result mismatch: expected %s/%s, got %s/%s"
          Session_permission.Id.pp permission expected_call_id expected_name
          actual_call_id actual_name
    | Tool_claim (Tool_claim.Duplicate id) ->
        Format.asprintf "duplicate tool claim id: %a" Session_tool_claim.Id.pp
          id
    | Tool_claim (Tool_claim.Unknown id) ->
        Format.asprintf "unknown tool claim: %a" Session_tool_claim.Id.pp id
    | Tool_claim (Tool_claim.Not_pending id) ->
        Format.asprintf "tool claim is not pending: %a" Session_tool_claim.Id.pp
          id
    | Tool_claim (Tool_claim.Tool_call_not_pending { execution; call_id }) ->
        Format.asprintf "tool claim %a references non-pending tool call: %s"
          Session_tool_claim.Id.pp execution call_id
    | Tool_claim
        (Tool_claim.Result_mismatch
           {
             execution;
             expected_call_id;
             expected_name;
             actual_call_id;
             actual_name;
           }) ->
        Format.asprintf
          "tool claim %a result mismatch: expected %s/%s, got %s/%s"
          Session_tool_claim.Id.pp execution expected_call_id expected_name
          actual_call_id actual_name
    | Transcript error -> Transcript.Error.message error
    | Turn (Turn.Unresolved_waiting turn) ->
        Format.asprintf "turn has unresolved waiting: %a" Session_turn.Id.pp
          turn

  let pp ppf t = Format.pp_print_string ppf (message t)
end

type turn_record = {
  turn : Turn.t;
  outcome : Turn.Outcome.t option;
  response_count : int;
  final_text : string option;
}

type permission_record = {
  request : Permission.Requested.t;
  resolved : Permission.Resolved.t option;
}

type tool_claim_record = {
  execution : Tool_claim.Started.t;
  finished : Tool_claim.Finished.t option;
}

type t = {
  transcript : Transcript.t;
  (* Usage of the latest replay response with recorded usage, paired with the
     transcript message count right after that response was appended. The
     count locates the suffix of messages not yet covered by the usage. *)
  replay_usage : (Spice_llm.Usage.t * int) option;
  compactions_rev : Compaction.t list;
  turn_order_rev : Turn.Id.t list;
  turns : turn_record Turn_map.t;
  active_turn : Turn.Id.t option;
  permission_order_rev : Permission.Id.t list;
  permissions : permission_record Permission_map.t;
  tool_claim_order_rev : Tool_claim.Id.t list;
  tool_claims : tool_claim_record Tool_claim_map.t;
  grants : Policy.Grants.t;
}

let empty =
  {
    transcript = Transcript.empty;
    replay_usage = None;
    compactions_rev = [];
    turn_order_rev = [];
    turns = Turn_map.empty;
    active_turn = None;
    permission_order_rev = [];
    permissions = Permission_map.empty;
    tool_claim_order_rev = [];
    tool_claims = Tool_claim_map.empty;
    grants = Policy.Grants.empty;
  }

let transcript t = t.transcript

let assistant_text assistant =
  Spice_llm.Message.Assistant.texts assistant
  |> String.concat "\n" |> String.trim

let response_text response =
  String.trim (Spice_llm.Response.text ~sep:"\n" response)

let final_text t =
  let rec loop = function
    | [] -> None
    | Spice_llm.Message.Assistant assistant :: rest ->
        let text = assistant_text assistant in
        if String.is_empty text then loop rest else Some text
    | ( Spice_llm.Message.System _ | Spice_llm.Message.Developer _
      | Spice_llm.Message.User _ | Spice_llm.Message.Tool_result _ )
      :: rest ->
        loop rest
  in
  loop (List.rev (Transcript.messages t.transcript))

let turn_final_text id t =
  match Turn_map.find_opt id t.turns with
  | None -> None
  | Some record -> record.final_text

let replay_usage t =
  Option.map
    (fun (usage, covered) ->
      (usage, List.drop covered (Transcript.messages t.transcript)))
    t.replay_usage

let compactions t = List.rev t.compactions_rev

let latest_compaction t =
  match t.compactions_rev with [] -> None | compaction :: _ -> Some compaction

let active_turn t = t.active_turn
let grants t = t.grants

let turns t =
  List.filter_map
    (fun id -> Option.map (fun r -> r.turn) (Turn_map.find_opt id t.turns))
    (List.rev t.turn_order_rev)

let turn id t = Option.map (fun r -> r.turn) (Turn_map.find_opt id t.turns)

let turn_outcome id t =
  Option.bind (Turn_map.find_opt id t.turns) (fun record -> record.outcome)

let turn_response_count id t =
  Option.map
    (fun record -> record.response_count)
    (Turn_map.find_opt id t.turns)

let latest_model t =
  let turn_model id =
    Option.map
      (fun record -> Turn.model record.turn)
      (Turn_map.find_opt id t.turns)
  in
  match t.active_turn with
  | Some id -> turn_model id
  | None -> (
      match t.turn_order_rev with [] -> None | id :: _ -> turn_model id)

let is_active_turn turn t =
  match t.active_turn with
  | Some active -> Turn.Id.equal active turn
  | None -> false

let permission_is_pending record t =
  match record.resolved with
  | Some _ -> false
  | None -> is_active_turn (Permission.Requested.turn record.request) t

let pending_permissions t =
  List.filter_map
    (fun id ->
      match Permission_map.find_opt id t.permissions with
      | Some record when permission_is_pending record t -> Some record.request
      | None | Some _ -> None)
    (List.rev t.permission_order_rev)

let pending_permission id t =
  match Permission_map.find_opt id t.permissions with
  | Some record when permission_is_pending record t -> Some record.request
  | None | Some _ -> None

let permissions t =
  List.filter_map
    (fun id ->
      Option.map
        (fun record -> (record.request, record.resolved))
        (Permission_map.find_opt id t.permissions))
    (List.rev t.permission_order_rev)

let tool_claim_is_pending record t =
  match record.finished with
  | Some _ -> false
  | None -> is_active_turn (Tool_claim.Started.turn record.execution) t

let pending_tool_claims t =
  List.filter_map
    (fun id ->
      match Tool_claim_map.find_opt id t.tool_claims with
      | Some record when tool_claim_is_pending record t -> Some record.execution
      | None | Some _ -> None)
    (List.rev t.tool_claim_order_rev)

let pending_tool_claim id t =
  match Tool_claim_map.find_opt id t.tool_claims with
  | Some record when tool_claim_is_pending record t -> Some record.execution
  | None | Some _ -> None

let tool_claims t =
  List.filter_map
    (fun id ->
      Option.map
        (fun record -> (record.execution, record.finished))
        (Tool_claim_map.find_opt id t.tool_claims))
    (List.rev t.tool_claim_order_rev)

let waiting t =
  List.map Waiting.permission (pending_permissions t)
  @ List.map Waiting.tool_claim (pending_tool_claims t)

let turn_error error = Error (Error.Turn error)
let permission_error error = Error (Error.Permission error)
let tool_claim_error error = Error (Error.Tool_claim error)
let transcript_error error = Error (Error.Transcript error)

let result_matches_call result call =
  String.equal
    (Spice_llm.Tool.Result.call_id result)
    (Spice_llm.Tool.Call.id call)
  && String.equal
       (Spice_llm.Tool.Result.name result)
       (Spice_llm.Tool.Call.name call)

let require_no_active_turn t =
  match t.active_turn with
  | None -> Ok ()
  | Some turn -> turn_error (Error.Turn.Active turn)

let require_active_turn t =
  match t.active_turn with
  | Some turn -> Ok turn
  | None -> turn_error Error.Turn.No_active

let require_started_turn turn t =
  match Turn_map.find_opt turn t.turns with
  | None -> turn_error (Error.Turn.Unknown turn)
  | Some record -> Ok record

let require_unfinished_turn turn t =
  match require_started_turn turn t with
  | Error _ as error -> error
  | Ok { outcome = Some _; _ } -> turn_error (Error.Turn.Finished turn)
  | Ok record -> Ok record

let require_active_turn_id turn t =
  match require_unfinished_turn turn t with
  | Error _ as error -> error
  | Ok _ -> (
      match t.active_turn with
      | Some active when Turn.Id.equal active turn -> Ok ()
      | Some active -> turn_error (Error.Turn.Active active)
      | None -> turn_error Error.Turn.No_active)

let add_transcript message t =
  match Transcript.add message t.transcript with
  | Ok transcript -> Ok { t with transcript }
  | Error error -> transcript_error error

let add_response response t =
  match Transcript.add_response response t.transcript with
  | Error error -> transcript_error error
  | Ok transcript -> Ok { t with transcript }

let transcript_of_input input transcript =
  match input with
  | Turn.Input.Continue -> Ok transcript
  | Session_turn.Input.User content -> (
      match Transcript.add (Spice_llm.Message.user content) transcript with
      | Ok transcript -> Ok transcript
      | Error error -> transcript_error error)

let apply_turn_started turn t =
  match require_no_active_turn t with
  | Error _ as error -> error
  | Ok () -> (
      let id = Turn.id turn in
      if Turn_map.mem id t.turns then turn_error (Error.Turn.Duplicate id)
      else
        match transcript_of_input (Turn.input turn) t.transcript with
        | Error _ as error -> error
        | Ok transcript ->
            Ok
              {
                t with
                transcript;
                turn_order_rev = id :: t.turn_order_rev;
                turns =
                  Turn_map.add id
                    {
                      turn;
                      outcome = None;
                      response_count = 0;
                      final_text = None;
                    }
                    t.turns;
                active_turn = Some id;
              })

let apply_message_appended message t =
  match message with
  | Spice_llm.Message.Tool_result _ -> (
      match require_active_turn t with
      | Error _ as error -> error
      | Ok _ -> add_transcript message t)
  | Spice_llm.Message.System _ | Spice_llm.Message.Developer _
  | Spice_llm.Message.User _ -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () -> add_transcript message t)
  (* [Event.check_message] rejects [Assistant] in both the smart constructor and
     the decoder, so a [Message_appended] never carries an assistant message. *)
  | Spice_llm.Message.Assistant _ -> assert false

let apply_response_appended response t =
  match require_active_turn t with
  | Error _ as error -> error
  | Ok active -> (
      let turn = Turn_map.find active t.turns in
      let expected = Turn.model turn.turn in
      let actual = Spice_llm.Response.model response in
      if not (Spice_llm.Model.equal actual expected) then
        turn_error
          (Error.Turn.Response_model_mismatch
             { turn = active; expected; actual })
      else
        match add_response response t with
        | Error _ as error -> error
        | Ok t ->
            let text = response_text response in
            let final_text =
              if String.is_empty text then turn.final_text else Some text
            in
            let turn =
              {
                turn with
                response_count = turn.response_count + 1;
                final_text;
              }
            in
            let replay_usage =
              match Spice_llm.Response.usage response with
              | None -> t.replay_usage
              | Some usage -> Some (usage, Transcript.length t.transcript)
            in
            Ok { t with replay_usage; turns = Turn_map.add active turn t.turns }
      )

let apply_compaction_installed compaction t =
  match Transcript.require_ready t.transcript with
  | Error error -> transcript_error error
  | Ok () -> (
      let transcript = Compaction.transcript compaction in
      match Transcript.require_ready transcript with
      | Error error -> transcript_error error
      | Ok () ->
          Ok
            {
              t with
              transcript;
              replay_usage = None;
              compactions_rev = compaction :: t.compactions_rev;
            })

let apply_permission_requested request t =
  let id = Permission.Requested.id request in
  if Permission_map.mem id t.permissions then
    permission_error (Error.Permission.Duplicate id)
  else
    match require_active_turn_id (Permission.Requested.turn request) t with
    | Error _ as error -> error
    | Ok () ->
        let tool_call = Permission.Requested.tool_call request in
        if
          List.exists
            (Spice_llm.Tool.Call.equal tool_call)
            (Transcript.pending t.transcript)
        then
          Ok
            {
              t with
              permission_order_rev = id :: t.permission_order_rev;
              permissions =
                Permission_map.add id { request; resolved = None } t.permissions;
            }
        else
          permission_error
            (Error.Permission.Tool_call_not_pending
               { permission = id; call_id = Spice_llm.Tool.Call.id tool_call })

let apply_permission_resolved resolution t =
  let id = Permission.Resolved.id resolution in
  match Permission_map.find_opt id t.permissions with
  | None -> permission_error (Error.Permission.Unknown id)
  | Some record -> (
      if not (permission_is_pending record t) then
        permission_error (Error.Permission.Not_pending id)
      else
        match Permission.Resolved.decision resolution with
        | Permission.Resolved.Deny result -> (
            let call = Permission.Requested.tool_call record.request in
            if not (result_matches_call result call) then
              permission_error
                (Error.Permission.Result_mismatch
                   {
                     permission = id;
                     expected_call_id = Spice_llm.Tool.Call.id call;
                     expected_name = Spice_llm.Tool.Call.name call;
                     actual_call_id = Spice_llm.Tool.Result.call_id result;
                     actual_name = Spice_llm.Tool.Result.name result;
                   })
            else
              match add_transcript (Spice_llm.Message.tool_result result) t with
              | Error _ as error -> error
              | Ok t ->
                  Ok
                    {
                      t with
                      permissions =
                        Permission_map.add id
                          { record with resolved = Some resolution }
                          t.permissions;
                    })
        | Permission.Resolved.Allow scope ->
            (* Grants follow the allow scope directly: [Session] adds the
               request's asked accesses, [Once] leaves them untouched. Going
               through [Policy.Review.resolve] here would force a [Rejected]
               arm that an allow can never produce. *)
            let grants =
              Policy.Review.grant
                (Permission.Requested.review record.request)
                scope t.grants
            in
            Ok
              {
                t with
                grants;
                permissions =
                  Permission_map.add id
                    { record with resolved = Some resolution }
                    t.permissions;
              })

let apply_tool_claim_started execution t =
  let id = Tool_claim.Started.id execution in
  if Tool_claim_map.mem id t.tool_claims then
    tool_claim_error (Error.Tool_claim.Duplicate id)
  else
    match require_active_turn_id (Tool_claim.Started.turn execution) t with
    | Error _ as error -> error
    | Ok () -> (
        match waiting t with
        | waiting :: _ ->
            turn_error (Error.Turn.Unresolved_waiting (Waiting.turn waiting))
        | [] ->
            let call = Tool_claim.Started.call execution in
            if
              List.exists
                (Spice_llm.Tool.Call.equal call)
                (Transcript.pending t.transcript)
            then
              Ok
                {
                  t with
                  tool_claim_order_rev = id :: t.tool_claim_order_rev;
                  tool_claims =
                    Tool_claim_map.add id
                      { execution; finished = None }
                      t.tool_claims;
                }
            else
              tool_claim_error
                (Error.Tool_claim.Tool_call_not_pending
                   { execution = id; call_id = Spice_llm.Tool.Call.id call }))

let apply_tool_claim_finished finished t =
  let id = Tool_claim.Finished.id finished in
  match Tool_claim_map.find_opt id t.tool_claims with
  | None -> tool_claim_error (Error.Tool_claim.Unknown id)
  | Some record -> (
      if not (tool_claim_is_pending record t) then
        tool_claim_error (Error.Tool_claim.Not_pending id)
      else
        let call = Tool_claim.Started.call record.execution in
        let result = Tool_claim.Finished.result finished in
        if not (result_matches_call result call) then
          tool_claim_error
            (Error.Tool_claim.Result_mismatch
               {
                 execution = id;
                 expected_call_id = Spice_llm.Tool.Call.id call;
                 expected_name = Spice_llm.Tool.Call.name call;
                 actual_call_id = Spice_llm.Tool.Result.call_id result;
                 actual_name = Spice_llm.Tool.Result.name result;
               })
        else
          match add_transcript (Spice_llm.Message.tool_result result) t with
          | Error _ as error -> error
          | Ok t ->
              Ok
                {
                  t with
                  tool_claims =
                    Tool_claim_map.add id
                      { record with finished = Some finished }
                      t.tool_claims;
                })

let clean_outcome = function
  | Turn.Outcome.Completed | Session_turn.Outcome.Step_limit -> true
  | Session_turn.Outcome.Failed _ | Session_turn.Outcome.Interrupted _ -> false

let require_clean_finish turn t =
  if waiting t <> [] then turn_error (Error.Turn.Unresolved_waiting turn)
  else
    match Transcript.require_ready t.transcript with
    | Ok () -> Ok ()
    | Error error -> transcript_error error

let apply_turn_finished ~turn ~outcome t =
  match require_active_turn_id turn t with
  | Error _ as error -> error
  | Ok () -> (
      match
        if clean_outcome outcome then require_clean_finish turn t else Ok ()
      with
      | Error _ as error -> error
      | Ok () ->
          let record = Turn_map.find turn t.turns in
          Ok
            {
              t with
              turns =
                Turn_map.add turn { record with outcome = Some outcome } t.turns;
              active_turn = None;
            })

let apply event t =
  match event with
  | Event.Turn_started turn -> apply_turn_started turn t
  | Event.Message_appended message -> apply_message_appended message t
  | Event.Response_appended response -> apply_response_appended response t
  | Event.Compaction_installed compaction ->
      apply_compaction_installed compaction t
  | Event.Permission_requested request -> apply_permission_requested request t
  | Event.Permission_resolved resolution ->
      apply_permission_resolved resolution t
  | Event.Tool_claim_started execution -> apply_tool_claim_started execution t
  | Event.Tool_claim_finished execution -> apply_tool_claim_finished execution t
  | Event.Turn_finished { turn; outcome } ->
      apply_turn_finished ~turn ~outcome t

let apply_all events t =
  let rec loop t = function
    | [] -> Ok t
    | event :: events -> (
        match apply event t with
        | Error _ as error -> error
        | Ok t -> loop t events)
  in
  loop t events

let of_events events = apply_all events empty
