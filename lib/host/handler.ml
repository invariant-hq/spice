(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

type t =
  cancelled:(unit -> bool) ->
  Spice_session_store.Document.t ->
  Spice_llm.Tool.Call.t ->
  (Spice_llm.Tool.Result.t option, Spice_protocol.Error.t) result

let result_text ?(error = false) call text =
  if String.is_empty text then Spice_llm.Tool.Result.empty ~error call
  else Spice_llm.Tool.Result.text ~error call text

(* A subagent-lifecycle tool answers [call] with its text either way: an
   [Error] payload is a model-visible refusal, not an execution failure, so it
   settles as an errored tool result rather than propagating up. *)
let answer call = function
  | Ok text -> Ok (Some (result_text call text))
  | Error text -> Ok (Some (result_text ~error:true call text))

let first handlers ~cancelled document call =
  let rec loop = function
    | [] -> Ok None
    | handler :: rest -> (
        match handler ~cancelled document call with
        | Ok None -> loop rest
        | (Ok (Some _) | Error _) as result -> result)
  in
  loop handlers

let for_tool name handler ~cancelled document call =
  if String.equal (Spice_llm.Tool.Call.name call) name then
    handler ~cancelled document call
  else Ok None

let active_turn session =
  match Spice_session.State.active_turn_id (Spice_session.state session) with
  | Some turn -> Ok turn
  | None ->
      Error
        (Spice_protocol.Error.Internal
           "host workflow tool call has no active turn")

let handle_todo ~fs ~root document call todos =
  let session = Spice_session_store.Document.session document in
  let* () =
    Artifacts.Todo.save ~fs ~root ~session:(Spice_session.id session) todos
    |> Result.map_error Artifacts.Error.to_protocol_error
  in
  let text =
    Printf.sprintf "Todo list updated: %d items."
      (List.length (Spice_protocol.Todo.items todos))
  in
  Ok (Some (result_text call text))

(* How a decoded proposal resolves once storage is attempted: it either parks
   the turn (saved) or is rejected with a model-visible message. A hard storage
   failure is a separate [Error], not one of these. *)
type plan_stored = Parked | Rejected of string

let handle_plan ~fs ~root ~now document call proposal =
  let session = Spice_session_store.Document.session document in
  let* turn = active_turn session in
  let invalid message = Ok (Some (result_text ~error:true call message)) in
  let created_at = now () in
  let session_id = Spice_session.id session in
  let stored : (plan_stored, Artifacts.Error.t) result =
    let plan =
      let* source =
        Spice_protocol.Plan.Source.make ~session:session_id ~turn
          ~tool_call_id:(Spice_llm.Tool.Call.id call)
          ()
      in
      Spice_protocol.Plan.propose
        ~id:(Spice_protocol.Plan.Proposal.id proposal)
        ~source
        ?title:(Spice_protocol.Plan.Proposal.title proposal)
        ~body:(Spice_protocol.Plan.Proposal.body proposal)
        ~created_at ()
    in
    match plan with
    | Error message -> Ok (Rejected message)
    | Ok plan -> (
        match
          Artifacts.Plan.propose ~fs ~root ~superseded_at:created_at plan
        with
        | Ok Artifacts.Plan.Stored -> Ok Parked
        | Ok (Artifacts.Plan.Refused message) -> Ok (Rejected message)
        | Error error -> Error error)
  in
  match stored with
  | Error error -> Error (Artifacts.Error.to_protocol_error error)
  | Ok (Rejected message) -> invalid message
  (* A valid saved proposal parks the turn: the model receives no immediate
     result and the session blocks on the plan boundary. *)
  | Ok Parked -> Ok None

(* Catalog absence is UX, not enforcement: a goal report reaching a plan or
   review turn — replay, or a malformed response — is refused here, before any
   artifact mutation. *)
let handle_goal ~fs ~root ~now ~mode document call update =
  match (mode : Spice_protocol.Mode.t) with
  | Spice_protocol.Mode.Plan | Spice_protocol.Mode.Review ->
      Ok
        (Some
           (result_text ~error:true call
              ("update_goal is not available in "
              ^ Spice_protocol.Mode.to_string mode
              ^ " mode.")))
  | Spice_protocol.Mode.Build -> (
      let session = Spice_session_store.Document.session document in
      let* resolved =
        Artifacts.Goal.update ~fs ~root ~now:(now ())
          ~session:(Spice_session.id session) update
        |> Result.map_error Artifacts.Error.to_protocol_error
      in
      match resolved with
      | Artifacts.Goal.Updated text -> Ok (Some (result_text call text))
      | Artifacts.Goal.Refused text ->
          Ok (Some (result_text ~error:true call text)))

let disallowed_subagent_message ~mode role =
  "spawn_subagent role "
  ^ Spice_protocol.Subagent.Role.to_string role
  ^ " is not allowed in "
  ^ Spice_protocol.Mode.to_string mode
  ^ " mode."

let handle_subagent ~mode ~spawn document call spawn_request =
  let role = Spice_protocol.Subagent.Spawn.role spawn_request in
  if Spice_protocol.Mode.allows_role mode role then
    answer call (spawn spawn_request ~parent:document)
  else
    Ok
      (Some
         (result_text ~error:true call (disallowed_subagent_message ~mode role)))

let collaboration_tool_name name =
  String.equal name Spice_protocol.Subagent.name
  || String.equal name Spice_protocol.Subagent.Wait.name
  || String.equal name Spice_protocol.Subagent.Cancel.name
  || String.equal name Spice_protocol.Subagent.Message.name
  || String.equal name Spice_protocol.Subagent.Message_parent.name

(* A child carries the collaboration half of the root handler over the same
   registry. [message_parent] is the one asymmetric operation: leaving it
   unanswered parks the child so the registry can relay the ask. Root workflow
   calls stay unavailable because they would mutate the child's session-local
   artifacts or park on a boundary no root workflow surface owns. *)
let subagent ~mode ~spawn ~wait ~cancel ~message ~cancelled document call =
  match Spice_protocol.Call.classify call with
  | None -> Ok None
  | Some (Spice_protocol.Call.Subagent_message_parent _) -> Ok None
  | Some (Spice_protocol.Call.Subagent spawn_request) ->
      handle_subagent ~mode ~spawn document call spawn_request
  | Some (Spice_protocol.Call.Subagent_wait request) ->
      answer call (wait ~cancelled request)
  | Some (Spice_protocol.Call.Subagent_cancel request) ->
      answer call (cancel request)
  | Some (Spice_protocol.Call.Subagent_message request) ->
      answer call (message request)
  | Some
      ( Spice_protocol.Call.Question _ | Spice_protocol.Call.Plan _
      | Spice_protocol.Call.Todo _ | Spice_protocol.Call.Goal _ ) ->
      Ok
        (Some
           (result_text ~error:true call
              (Spice_llm.Tool.Call.name call
              ^ " is not available in a subagent session.")))
  | Some (Spice_protocol.Call.Invalid { name; error }) ->
      if collaboration_tool_name name then
        Ok (Some (result_text ~error:true call error))
      else
        Ok
          (Some
             (result_text ~error:true call
                (name ^ " is not available in a subagent session.")))

let defaults ~fs ~root ~now ~mode ~spawn ~wait ~cancel ~message ~cancelled
    document call =
  match Spice_protocol.Call.classify call with
  | None -> Ok None
  (* A question parks the turn on the answerable question boundary; the loop
     surfaces it, this handler does not answer it. *)
  | Some (Spice_protocol.Call.Question _) -> Ok None
  | Some (Spice_protocol.Call.Todo todos) ->
      handle_todo ~fs ~root document call todos
  | Some (Spice_protocol.Call.Plan proposal) ->
      handle_plan ~fs ~root ~now document call proposal
  | Some (Spice_protocol.Call.Goal update) ->
      handle_goal ~fs ~root ~now ~mode document call update
  | Some (Spice_protocol.Call.Subagent spawn_request) ->
      handle_subagent ~mode ~spawn document call spawn_request
  | Some (Spice_protocol.Call.Subagent_wait request) ->
      answer call (wait ~cancelled request)
  | Some (Spice_protocol.Call.Subagent_cancel request) ->
      answer call (cancel request)
  | Some (Spice_protocol.Call.Subagent_message request) ->
      answer call (message request)
  | Some (Spice_protocol.Call.Subagent_message_parent _) ->
      Ok
        (Some
           (result_text ~error:true call
              "message_parent is only available in a subagent session."))
  | Some (Spice_protocol.Call.Invalid { name; error }) ->
      (* An undecodable question stays answerable, so it parks like a valid one;
         any other undecodable host tool returns the decode error so the model
         can correct its call. *)
      if String.equal name Spice_protocol.Question.name then Ok None
      else Ok (Some (result_text ~error:true call error))
