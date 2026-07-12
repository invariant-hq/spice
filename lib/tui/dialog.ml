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

type t = { pending : pending; form : form }

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
    (fun form -> { pending = { owner; boundary }; form })
    form

let pending t = t.pending

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
  | Flash of string

let quote text = "\"" ^ text ^ "\""

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
      | Permission_dialog.Deny message ->
          let echo =
            match message with
            | None -> "denied"
            | Some message -> "denied · " ^ quote message
          in
          ( t,
            Resolve
              {
                resolution =
                  Reply
                    {
                      answer = Spice_session.Permission.Resolved.Deny;
                      message;
                    };
                echo;
              } ))
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
      | Plan_dialog.Adjust text ->
          let decision =
            match Spice_protocol.Plan.Decision.reject_with_reason text with
            | Ok decision -> decision
            | Error error ->
                invalid_arg
                  (Format.asprintf "%a" Spice_protocol.Plan.Decision.pp_error
                     error)
          in
          ( t,
            Resolve
              {
                resolution = Resolve_plan { decision };
                echo = "plan rejected · " ^ quote text;
              } )
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
      | Question_dialog.Flash message -> (t, Flash message))

let accepts_paste t =
  match t.form with
  | Question question -> Question_dialog.accepts_paste question
  | Permission permission -> Permission_dialog.accepts_paste permission
  | Plan plan -> Plan_dialog.accepts_paste plan

let paste text t =
  match t.form with
  | Question question ->
      { t with form = Question (Question_dialog.paste text question) }
  | Permission permission ->
      { t with form = Permission (Permission_dialog.paste text permission) }
  | Plan plan -> { t with form = Plan (Plan_dialog.paste text plan) }

(* --- View --- *)

let view ~width t =
  match t.form with
  | Permission d -> Permission_dialog.view ~width d
  | Plan d -> Plan_dialog.view ~width d
  | Question d -> Question_dialog.view ~width d
