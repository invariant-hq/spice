(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type owner = Main | Child of Spice_session.Id.t
type pending = { owner : owner; boundary : Spice_protocol.Pending.t }

type form =
  | Permission of Permission_dialog.t
  | Plan of Plan_dialog.t
  | Question of Question_dialog.t

(* The composer-borrow kind, so a resumed submit knows which reply it finishes.
   [Custom] carries the question form because its emptiness rule differs (a plan
   adjust or a deny may submit empty; a custom answer may not). *)
type feedback = Deny | Adjust | Custom
type t = { pending : pending; form : form; feedback : feedback option }

let of_pending ~owner boundary =
  let form =
    match (boundary : Spice_protocol.Pending.t) with
    | Spice_protocol.Pending.Permission request ->
        Some (Permission (Permission_dialog.make request))
    | Spice_protocol.Pending.Plan { proposal; _ } ->
        Some (Plan (Plan_dialog.make proposal))
    | Spice_protocol.Pending.Question { question; _ } ->
        Some (Question (Question_dialog.of_request question))
    | Spice_protocol.Pending.Host_tool { call; _ } -> (
        match Spice_protocol.Call.answerable_question call with
        | Some text -> Some (Question (Question_dialog.of_text text))
        | None -> None)
  in
  Option.map
    (fun form -> { pending = { owner; boundary }; form; feedback = None })
    form

let pending t = t.pending
let borrowed t = Option.is_some t.feedback

type resolution =
  | Reply of {
      answer : Spice_session.Permission.Resolved.answer;
      message : string option;
    }
  | Answer of { text : string }
  | Resolve_plan of { decision : Spice_protocol.Plan.Decision.t }

type event =
  | Stay
  | Resolve of { resolution : resolution; echo : string }
  | Borrow of { placeholder : string }
  | Flash of string

let deny_placeholder = "tell Spice what to do differently"
let adjust_placeholder = "what should the plan do differently?"
let custom_placeholder = "type your answer"

(* --- Key folding, per form --- *)

let key ev t =
  match t.form with
  | Permission d -> (
      let d, outcome = Permission_dialog.key ev d in
      let t = { t with form = Permission d } in
      match outcome with
      | Permission_dialog.Stay -> (t, Stay)
      | Permission_dialog.Allow scope ->
          let echo =
            match scope with
            | Spice_session.Permission.Resolved.Once -> "allowed once"
            | Spice_session.Permission.Resolved.Exact_for_conversation ->
                "allowed for this conversation · "
                ^ Permission_dialog.scope_label d
            | Spice_session.Permission.Resolved.Family _ ->
                assert false
          in
          ( t,
            Resolve
              {
                resolution =
                  Reply
                    {
                      answer = Spice_session.Permission.Resolved.Allow scope;
                      message = None;
                    };
                echo;
              } )
      | Permission_dialog.Deny ->
          ( { t with feedback = Some Deny },
            Borrow { placeholder = deny_placeholder } ))
  | Plan d -> (
      let d, outcome = Plan_dialog.key ev d in
      let t = { t with form = Plan d } in
      match outcome with
      | Plan_dialog.Stay -> (t, Stay)
      | Plan_dialog.Approve ->
          ( t,
            Resolve
              {
                resolution =
                  Resolve_plan
                    { decision = Spice_protocol.Plan.Decision.approve };
                echo = "plan approved · building";
              } )
      | Plan_dialog.Adjust ->
          ( { t with feedback = Some Adjust },
            Borrow { placeholder = adjust_placeholder } )
      | Plan_dialog.Keep_planning ->
          ( t,
            Resolve
              {
                resolution =
                  Resolve_plan
                    { decision = Spice_protocol.Plan.Decision.reject };
                echo = "kept planning";
              } ))
  | Question d -> (
      let d, outcome = Question_dialog.key ev d in
      let t = { t with form = Question d } in
      match outcome with
      | Question_dialog.Stay -> (t, Stay)
      | Question_dialog.Answer text ->
          (t, Resolve { resolution = Answer { text }; echo = "answered" })
      | Question_dialog.Custom ->
          ( { t with feedback = Some Custom },
            Borrow { placeholder = custom_placeholder } )
      | Question_dialog.Flash message -> (t, Flash message))

(* --- Borrow lifecycle --- *)

let borrow_summary t =
  match (t.feedback, t.form) with
  | Some Deny, Permission d -> "Denying: " ^ Permission_dialog.summary d
  | Some Adjust, _ -> "Adjusting the plan"
  | Some Custom, Question _ -> "Type your answer"
  | _ -> ""

let quote text = "\"" ^ text ^ "\""

let resolve_borrow ~text t =
  let text = String.trim text in
  match t.feedback with
  | Some Deny ->
      let message = if String.length text = 0 then None else Some text in
      let echo =
        match message with None -> "denied" | Some m -> "denied · " ^ quote m
      in
      Ok
        (Reply { answer = Spice_session.Permission.Resolved.Deny; message }, echo)
  | Some Adjust ->
      if String.length text = 0 then
        Ok
          ( Resolve_plan
              { decision = Spice_protocol.Plan.Decision.reject },
            "kept planning" )
      else
        Ok
          ( Resolve_plan
              {
                decision =
                  (match
                     Spice_protocol.Plan.Decision.reject_with_reason text
                   with
                  | Ok decision -> decision
                  | Error error ->
                      invalid_arg
                        (Format.asprintf "%a"
                           Spice_protocol.Plan.Decision.pp_error error))
              },
            "plan rejected · " ^ quote text )
  | Some Custom ->
      if String.length text = 0 then Error "type an answer"
      else Ok (Answer { text }, "answered")
  | None -> Error "no answer is being collected"

let cancel_borrow t = { t with feedback = None }

(* --- View --- *)

let view ~width t =
  match t.form with
  | Permission d -> Permission_dialog.view ~width d
  | Plan d -> Plan_dialog.view ~width d
  | Question d -> Question_dialog.view ~width d
