(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Start of Spice_session.Turn.t
  | Resume
  | Reply of {
      permission : Spice_session.Permission.Id.t;
      answer : Spice_permission.Policy.Review.answer;
      via : Spice_session.Permission.Resolved.via option;
      message : string option;
    }
  | Answer of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      text : string;
    }
  | Resolve_plan of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      decision : Plan.Decision.t;
    }
  | Finish_tool of
      Spice_session.Tool_claim.Id.t * Spice_tool.Output.t Spice_tool.Result.t
  | Interrupt of { reason : string option }

let pp_answer ppf (answer : Spice_permission.Policy.Review.answer) =
  match answer with
  | Spice_permission.Policy.Review.Allow Spice_permission.Policy.Review.Once ->
      Format.pp_print_string ppf "allow-once"
  | Spice_permission.Policy.Review.Allow Spice_permission.Policy.Review.Session
    ->
      Format.pp_print_string ppf "allow-session"
  | Spice_permission.Policy.Review.Deny -> Format.pp_print_string ppf "deny"

let pp_via ppf = function
  | `Reviewer -> Format.pp_print_string ppf "reviewer"
  | `Unattended -> Format.pp_print_string ppf "unattended"

let pp_result ppf result =
  match Spice_tool.Result.status result with
  | Spice_tool.Result.Completed -> Format.pp_print_string ppf "completed"
  | Spice_tool.Result.Failed { message; _ } ->
      Format.fprintf ppf "failed(%S)" message
  | Spice_tool.Result.Interrupted { reason; _ } ->
      Format.fprintf ppf "interrupted(%S)" reason

let pp ppf = function
  | Start turn ->
      Format.fprintf ppf "@[<hov>start %a@]" Spice_session.Turn.pp turn
  | Resume -> Format.pp_print_string ppf "resume"
  | Reply { permission; answer; via; message } ->
      Format.fprintf ppf
        "@[<hov>reply { permission = %a; answer = %a; via = %a; message = %a \
         }@]"
        Spice_session.Permission.Id.pp permission pp_answer answer
        (Format.pp_print_option pp_via)
        via
        (Format.pp_print_option Format.pp_print_string)
        message
  | Answer { turn; call_id; text } ->
      Format.fprintf ppf
        "@[<hov>answer { turn = %a; call_id = %s; text = %S }@]"
        Spice_session.Turn.Id.pp turn call_id text
  | Resolve_plan { turn; call_id; decision } ->
      Format.fprintf ppf
        "@[<hov>resolve_plan { turn = %a; call_id = %s; decision = %a }@]"
        Spice_session.Turn.Id.pp turn call_id Plan.Decision.pp decision
  | Finish_tool (id, result) ->
      Format.fprintf ppf "@[<hov>finish_tool %a %a@]"
        Spice_session.Tool_claim.Id.pp id pp_result result
  | Interrupt { reason } ->
      Format.fprintf ppf "@[<hov>interrupt %a@]"
        (Format.pp_print_option Format.pp_print_string)
        reason
