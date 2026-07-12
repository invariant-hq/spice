(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_session.Event" fn message

type t =
  | Turn_started of Turn.t
  | Message_appended of Spice_llm.Message.t
  | Response_appended of Spice_llm.Response.t
  | Assistant_interrupted of { text : string }
  | Compaction_installed of Compaction.t
  | Permission_requested of Permission.Requested.t
  | Permission_resolved of Permission.Resolved.t
  | Tool_claim_started of Tool_claim.Started.t
  | Tool_claim_finished of Tool_claim.Finished.t
  | Turn_finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }

let turn_started turn = Turn_started turn

let check_message = function
  | Spice_llm.Message.Assistant _ ->
      invalid "message_appended"
        "assistant messages must be recorded as completed responses"
  | Spice_llm.Message.System _ | Spice_llm.Message.Developer _
  | Spice_llm.Message.User _ | Spice_llm.Message.Tool_result _ ->
      ()

let message_appended message =
  check_message message;
  Message_appended message

let response_appended response = Response_appended response

let assistant_interrupted ~text =
  if String.is_empty (String.trim text) then
    invalid "assistant_interrupted" "text must contain visible prose";
  Assistant_interrupted { text }

let compaction_installed compaction = Compaction_installed compaction
let permission_requested request = Permission_requested request
let permission_resolved reply = Permission_resolved reply
let tool_claim_started execution = Tool_claim_started execution
let tool_claim_finished execution = Tool_claim_finished execution
let turn_finished ~turn outcome = Turn_finished { turn; outcome }

let equal a b =
  match (a, b) with
  | Turn_started a, Turn_started b -> Turn.equal a b
  | Message_appended a, Message_appended b -> Spice_llm.Message.equal a b
  | Response_appended a, Response_appended b -> Spice_llm.Response.equal a b
  | Assistant_interrupted a, Assistant_interrupted b ->
      String.equal a.text b.text
  | Compaction_installed a, Compaction_installed b -> Compaction.equal a b
  | Permission_requested a, Permission_requested b ->
      Permission.Requested.equal a b
  | Permission_resolved a, Permission_resolved b ->
      Permission.Resolved.equal a b
  | Tool_claim_started a, Tool_claim_started b -> Tool_claim.Started.equal a b
  | Tool_claim_finished a, Tool_claim_finished b ->
      Tool_claim.Finished.equal a b
  | Turn_finished a, Turn_finished b ->
      Turn.Id.equal a.turn b.turn && Turn.Outcome.equal a.outcome b.outcome
  | Turn_started _, _
  | Message_appended _, _
  | Response_appended _, _
  | Assistant_interrupted _, _
  | Compaction_installed _, _
  | Permission_requested _, _
  | Permission_resolved _, _
  | Tool_claim_started _, _
  | Tool_claim_finished _, _
  | Turn_finished _, _ ->
      false

let pp_message_kind ppf = function
  | Spice_llm.Message.System _ -> Format.pp_print_string ppf "system"
  | Spice_llm.Message.Developer _ -> Format.pp_print_string ppf "developer"
  | Spice_llm.Message.User _ -> Format.pp_print_string ppf "user"
  | Spice_llm.Message.Assistant _ -> Format.pp_print_string ppf "assistant"
  | Spice_llm.Message.Tool_result _ -> Format.pp_print_string ppf "tool-result"

let pp ppf = function
  | Turn_started turn -> Format.fprintf ppf "turn-started(%a)" Turn.pp turn
  | Message_appended message ->
      Format.fprintf ppf "message-appended(%a)" pp_message_kind message
  | Response_appended response ->
      Format.fprintf ppf "response-appended(%S)"
        (Spice_llm.Response.text response)
  | Assistant_interrupted { text } ->
      Format.fprintf ppf "assistant-interrupted(%S)" text
  | Compaction_installed compaction ->
      Format.fprintf ppf "compaction-installed(%a)" Compaction.pp compaction
  | Permission_requested request ->
      Format.fprintf ppf "permission-requested(%a)" Permission.Requested.pp
        request
  | Permission_resolved reply ->
      Format.fprintf ppf "permission-resolved(%a)" Permission.Resolved.pp reply
  | Tool_claim_started execution ->
      Format.fprintf ppf "tool-claim-started(%a)" Tool_claim.Started.pp
        execution
  | Tool_claim_finished execution ->
      Format.fprintf ppf "tool-claim-finished(%a)" Tool_claim.Finished.pp
        execution
  | Turn_finished { turn; outcome } ->
      Format.fprintf ppf "turn-finished(turn=%a, outcome=%a)" Turn.Id.pp turn
        Turn.Outcome.pp outcome

let jsont =
  let turn_started_case =
    Jsont.Object.map ~kind:"turn-started event" (fun turn -> Turn_started turn)
    |> Jsont.Object.mem "turn" Turn.jsont ~enc:(function
      | Turn_started turn -> turn
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "turn_started" ~dec:Fun.id
  in
  let message_appended_case =
    Jsont.Object.map ~kind:"message-appended event" (fun message ->
        decode_invalid_arg (fun () -> message_appended message))
    |> Jsont.Object.mem "message" Spice_llm.Message.jsont ~enc:(function
      | Message_appended message -> message
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "message_appended" ~dec:Fun.id
  in
  let response_appended_case =
    Jsont.Object.map ~kind:"response-appended event" (fun response ->
        Response_appended response)
    |> Jsont.Object.mem "response" Spice_llm.Response.jsont ~enc:(function
      | Response_appended response -> response
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "response_appended" ~dec:Fun.id
  in
  let assistant_interrupted_case =
    Jsont.Object.map ~kind:"assistant-interrupted event" (fun text ->
        decode_invalid_arg (fun () -> assistant_interrupted ~text))
    |> Jsont.Object.mem "text" Jsont.string ~enc:(function
      | Assistant_interrupted { text } -> text
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "assistant_interrupted" ~dec:Fun.id
  in
  let compaction_installed_case =
    Jsont.Object.map ~kind:"compaction-installed event" (fun compaction ->
        Compaction_installed compaction)
    |> Jsont.Object.mem "compaction" Compaction.jsont ~enc:(function
      | Compaction_installed compaction -> compaction
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "compaction_installed" ~dec:Fun.id
  in
  let permission_requested_case =
    Jsont.Object.map ~kind:"permission-requested event" (fun request ->
        Permission_requested request)
    |> Jsont.Object.mem "request" Permission.Requested.jsont ~enc:(function
      | Permission_requested request -> request
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "permission_requested" ~dec:Fun.id
  in
  let permission_resolved_case =
    Jsont.Object.map ~kind:"permission-resolved event" (fun reply ->
        Permission_resolved reply)
    |> Jsont.Object.mem "reply" Permission.Resolved.jsont ~enc:(function
      | Permission_resolved reply -> reply
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "permission_resolved" ~dec:Fun.id
  in
  let tool_claim_started_case =
    Jsont.Object.map ~kind:"tool-claim-started event" (fun execution ->
        Tool_claim_started execution)
    |> Jsont.Object.mem "execution" Tool_claim.Started.jsont ~enc:(function
      | Tool_claim_started execution -> execution
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "tool_claim_started" ~dec:Fun.id
  in
  let tool_claim_finished_case =
    Jsont.Object.map ~kind:"tool-claim-finished event" (fun execution ->
        Tool_claim_finished execution)
    |> Jsont.Object.mem "execution" Tool_claim.Finished.jsont ~enc:(function
      | Tool_claim_finished execution -> execution
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "tool_claim_finished" ~dec:Fun.id
  in
  let turn_finished_case =
    Jsont.Object.map ~kind:"turn-finished event" (fun turn outcome ->
        Turn_finished { turn; outcome })
    |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:(function
      | Turn_finished { turn; _ } -> turn
      | _ -> assert false)
    |> Jsont.Object.mem "outcome" Turn.Outcome.jsont ~enc:(function
      | Turn_finished { outcome; _ } -> outcome
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "turn_finished" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        turn_started_case;
        message_appended_case;
        response_appended_case;
        assistant_interrupted_case;
        compaction_installed_case;
        permission_requested_case;
        permission_resolved_case;
        tool_claim_started_case;
        tool_claim_finished_case;
        turn_finished_case;
      ]
  in
  let enc_case = function
    | Turn_started _ as event -> Jsont.Object.Case.value turn_started_case event
    | Message_appended _ as event ->
        Jsont.Object.Case.value message_appended_case event
    | Response_appended _ as event ->
        Jsont.Object.Case.value response_appended_case event
    | Assistant_interrupted _ as event ->
        Jsont.Object.Case.value assistant_interrupted_case event
    | Compaction_installed _ as event ->
        Jsont.Object.Case.value compaction_installed_case event
    | Permission_requested _ as event ->
        Jsont.Object.Case.value permission_requested_case event
    | Permission_resolved _ as event ->
        Jsont.Object.Case.value permission_resolved_case event
    | Tool_claim_started _ as event ->
        Jsont.Object.Case.value tool_claim_started_case event
    | Tool_claim_finished _ as event ->
        Jsont.Object.Case.value tool_claim_finished_case event
    | Turn_finished _ as event ->
        Jsont.Object.Case.value turn_finished_case event
  in
  Jsont.Object.map ~kind:"session event" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
