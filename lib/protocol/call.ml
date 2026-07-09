(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module type HOST_TOOL = sig
  type request

  val name : string
  val tool : Spice_llm.Tool.t
  val decode : Spice_llm.Tool.Call.t -> (request, string) result
end

module Kind = struct
  type t =
    | Question
    | Plan
    | Todo
    | Goal
    | Subagent
    | Subagent_wait
    | Subagent_cancel
    | Subagent_message
    | Subagent_message_parent

  let all =
    [
      Question;
      Plan;
      Todo;
      Goal;
      Subagent;
      Subagent_wait;
      Subagent_cancel;
      Subagent_message;
      Subagent_message_parent;
    ]

  let tool = function
    | Question -> Question.tool
    | Plan -> Plan.tool
    | Todo -> Todo.tool
    | Goal -> Goal.tool
    | Subagent -> Subagent.tool
    | Subagent_wait -> Subagent.Wait.tool
    | Subagent_cancel -> Subagent.Cancel.tool
    | Subagent_message -> Subagent.Message.tool
    | Subagent_message_parent -> Subagent.Message_parent.tool

  let name = function
    | Question -> Question.name
    | Plan -> Plan.name
    | Todo -> Todo.name
    | Goal -> Goal.name
    | Subagent -> Subagent.name
    | Subagent_wait -> Subagent.Wait.name
    | Subagent_cancel -> Subagent.Cancel.name
    | Subagent_message -> Subagent.Message.name
    | Subagent_message_parent -> Subagent.Message_parent.name

  let equal a b = a = b
  let pp ppf t = Format.pp_print_string ppf (name t)
end

type t =
  | Question of Question.Request.t
  | Plan of Plan.Proposal.t
  | Todo of Todo.t
  | Goal of Goal.Update.t
  | Subagent of Subagent.Spawn.t
  | Subagent_wait of Subagent.Wait.Request.t
  | Subagent_cancel of Subagent.Cancel.Request.t
  | Subagent_message of Subagent.Message.Request.t
  | Subagent_message_parent of Subagent.Message_parent.Request.t
  | Invalid of { name : string; error : string }

let classified name decoded ~request =
  match decoded with
  | Ok value -> Some (request value)
  | Error error -> Some (Invalid { name; error })

let classify call =
  let name = Spice_llm.Tool.Call.name call in
  if String.equal name Question.name then
    classified name (Question.decode call) ~request:(fun value ->
        Question value)
  else if String.equal name Plan.name then
    classified name (Plan.decode call) ~request:(fun value -> Plan value)
  else if String.equal name Todo.name then
    classified name (Todo.decode call) ~request:(fun value -> Todo value)
  else if String.equal name Goal.name then
    classified name (Goal.decode call) ~request:(fun value -> Goal value)
  else if String.equal name Subagent.name then
    classified name (Subagent.decode call) ~request:(fun value ->
        Subagent value)
  else if String.equal name Subagent.Wait.name then
    classified name (Subagent.Wait.decode call) ~request:(fun value ->
        Subagent_wait value)
  else if String.equal name Subagent.Cancel.name then
    classified name (Subagent.Cancel.decode call) ~request:(fun value ->
        Subagent_cancel value)
  else if String.equal name Subagent.Message.name then
    classified name (Subagent.Message.decode call) ~request:(fun value ->
        Subagent_message value)
  else if String.equal name Subagent.Message_parent.name then
    classified name (Subagent.Message_parent.decode call) ~request:(fun value ->
        Subagent_message_parent value)
  else None

let answerable_question = function
  | Question request -> Some (Question.Request.question request)
  | Invalid { name; error } when String.equal name Question.name ->
      Some ("Invalid question: " ^ error)
  | Plan _ | Todo _ | Goal _ | Subagent _ | Subagent_wait _ | Subagent_cancel _
  | Subagent_message _ | Subagent_message_parent _ | Invalid _ ->
      None

let answer_text call answer =
  match call with
  | Question _ -> Question.answer_text answer
  | Invalid { name; _ } when String.equal name Question.name ->
      Question.answer_text answer
  | Subagent_message_parent _ ->
      if String.is_empty answer then Error "answer must not be empty"
      else Ok answer
  | Plan _ | Todo _ | Goal _ | Subagent _ | Subagent_wait _
  | Subagent_cancel _ | Subagent_message _ | Invalid _ ->
      Error "the pending host tool does not accept a user answer"

let plan_proposal = function
  | Plan proposal -> Some proposal
  | Question _ | Todo _ | Goal _ | Subagent _ | Subagent_wait _
  | Subagent_cancel _ | Subagent_message _ | Subagent_message_parent _
  | Invalid _ ->
      None

let pp ppf = function
  | Question request ->
      Format.fprintf ppf "@[<hov>question %a@]" Question.Request.pp request
  | Plan proposal ->
      Format.fprintf ppf "@[<hov>plan %a@]" Plan.Proposal.pp proposal
  | Todo todos -> Format.fprintf ppf "@[<v>todo@ %a@]" Todo.pp todos
  | Goal update -> Format.fprintf ppf "@[<hov>goal %a@]" Goal.Update.pp update
  | Subagent spawn ->
      Format.fprintf ppf "@[<hov>subagent %a@]" Subagent.Spawn.pp spawn
  | Subagent_wait request ->
      Format.fprintf ppf "@[<hov>subagent wait %a@]" Subagent.Wait.Request.pp
        request
  | Subagent_cancel request ->
      Format.fprintf ppf "@[<hov>subagent cancel %a@]"
        Subagent.Cancel.Request.pp request
  | Subagent_message request ->
      Format.fprintf ppf "@[<hov>subagent message %a@]"
        Subagent.Message.Request.pp request
  | Subagent_message_parent request ->
      Format.fprintf ppf "@[<hov>parent message %a@]"
        Subagent.Message_parent.Request.pp request
  | Invalid { name; error } ->
      Format.fprintf ppf "@[<hov>invalid %s: %s@]" name error
