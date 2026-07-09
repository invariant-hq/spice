(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax
module Time = Spice_session.Time

let check_non_empty message = function
  | "" -> Error message
  | (_ : string) -> Ok ()

module Usage = struct
  type t = { prompt_tokens : int; completion_tokens : int; tool_uses : int }

  type field = Prompt_tokens | Completion_tokens | Tool_uses
  type error = Negative_count of { field : field; value : int }

  let field_name = function
    | Prompt_tokens -> "prompt_tokens"
    | Completion_tokens -> "completion_tokens"
    | Tool_uses -> "tool_uses"

  let pp_error ppf (Negative_count { field; value }) =
    Format.fprintf ppf "subagent usage %s must not be negative, got %d"
      (field_name field) value

  let check_count field value =
    if value < 0 then Error (Negative_count { field; value }) else Ok ()

  let make ~prompt_tokens ~completion_tokens ~tool_uses =
    let* () = check_count Prompt_tokens prompt_tokens in
    let* () = check_count Completion_tokens completion_tokens in
    let* () = check_count Tool_uses tool_uses in
    Ok { prompt_tokens; completion_tokens; tool_uses }

  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ prompt_tokens = %d; completion_tokens = %d; tool_uses = %d }@]"
      t.prompt_tokens t.completion_tokens t.tool_uses

  let jsont =
    Jsont.Object.map ~kind:"subagent usage"
      (fun prompt_tokens completion_tokens tool_uses ->
        make ~prompt_tokens ~completion_tokens ~tool_uses
        |> Result.map_error (Format.asprintf "%a" pp_error)
        |> Decode.or_error)
    |> Jsont.Object.mem "prompt_tokens" Jsont.int ~enc:(fun t ->
        t.prompt_tokens)
    |> Jsont.Object.mem "completion_tokens" Jsont.int ~enc:(fun t ->
        t.completion_tokens)
    |> Jsont.Object.mem "tool_uses" Jsont.int ~enc:(fun t -> t.tool_uses)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Status = struct
  type t =
    | Queued
    | Running of { started_at : Time.t }
    | Blocked of { blocked_at : Time.t; blocker : string }
    | Completed of {
        completed_at : Time.t;
        summary : string;
        usage : Usage.t option;
      }
    | Failed of { failed_at : Time.t; message : string; usage : Usage.t option }
    | Cancelled of { cancelled_at : Time.t; usage : Usage.t option }

  let queued = Queued
  let running ~started_at = Running { started_at }

  let blocked ~blocked_at ~blocker =
    let* () =
      check_non_empty "subagent blocker summary must not be empty" blocker
    in
    Ok (Blocked { blocked_at; blocker })

  let completed ~completed_at ~summary ?usage () =
    let* () = check_non_empty "subagent summary must not be empty" summary in
    Ok (Completed { completed_at; summary; usage })

  let failed ~failed_at ~message ?usage () =
    let* () =
      check_non_empty "subagent failure message must not be empty" message
    in
    Ok (Failed { failed_at; message; usage })

  let cancelled ~cancelled_at ?usage () = Cancelled { cancelled_at; usage }

  let transition_time = function
    | Queued -> None
    | Running { started_at } -> Some started_at
    | Blocked { blocked_at; _ } -> Some blocked_at
    | Completed { completed_at; _ } -> Some completed_at
    | Failed { failed_at; _ } -> Some failed_at
    | Cancelled { cancelled_at; _ } -> Some cancelled_at

  let to_string = function
    | Queued -> "queued"
    | Running _ -> "running"
    | Blocked _ -> "blocked"
    | Completed _ -> "completed"
    | Failed _ -> "failed"
    | Cancelled _ -> "cancelled"

  let equal a b = a = b
  let pp ppf status = Format.pp_print_string ppf (to_string status)

  let jsont =
    let usage_mem obj ~enc =
      Jsont.Object.opt_mem "usage" Usage.jsont ~enc obj
    in
    let queued_case =
      Jsont.Object.map ~kind:"queued subagent status" Queued
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "queued" ~dec:Fun.id
    in
    let running_case =
      Jsont.Object.map ~kind:"running subagent status" (fun started_at ->
          Running { started_at })
      |> Jsont.Object.mem "started_at" Time.jsont ~enc:(function
        | Running { started_at } -> started_at
        | Queued | Blocked _ | Completed _ | Failed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "running" ~dec:Fun.id
    in
    let blocked_case =
      Jsont.Object.map ~kind:"blocked subagent status"
        (fun blocked_at blocker ->
          Decode.or_error (blocked ~blocked_at ~blocker))
      |> Jsont.Object.mem "blocked_at" Time.jsont ~enc:(function
        | Blocked { blocked_at; _ } -> blocked_at
        | Queued | Running _ | Completed _ | Failed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.mem "blocker" Jsont.string ~enc:(function
        | Blocked { blocker; _ } -> blocker
        | Queued | Running _ | Completed _ | Failed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "blocked" ~dec:Fun.id
    in
    let completed_case =
      Jsont.Object.map ~kind:"completed subagent status"
        (fun completed_at summary usage ->
          Decode.or_error (completed ~completed_at ~summary ?usage ()))
      |> Jsont.Object.mem "completed_at" Time.jsont ~enc:(function
        | Completed { completed_at; _ } -> completed_at
        | Queued | Running _ | Blocked _ | Failed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.mem "summary" Jsont.string ~enc:(function
        | Completed { summary; _ } -> summary
        | Queued | Running _ | Blocked _ | Failed _ | Cancelled _ ->
            assert false)
      |> usage_mem ~enc:(function
        | Completed { usage; _ } -> usage
        | Queued | Running _ | Blocked _ | Failed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "completed" ~dec:Fun.id
    in
    let failed_case =
      Jsont.Object.map ~kind:"failed subagent status"
        (fun failed_at message usage ->
          Decode.or_error (failed ~failed_at ~message ?usage ()))
      |> Jsont.Object.mem "failed_at" Time.jsont ~enc:(function
        | Failed { failed_at; _ } -> failed_at
        | Queued | Running _ | Blocked _ | Completed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.mem "message" Jsont.string ~enc:(function
        | Failed { message; _ } -> message
        | Queued | Running _ | Blocked _ | Completed _ | Cancelled _ ->
            assert false)
      |> usage_mem ~enc:(function
        | Failed { usage; _ } -> usage
        | Queued | Running _ | Blocked _ | Completed _ | Cancelled _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "failed" ~dec:Fun.id
    in
    let cancelled_case =
      Jsont.Object.map ~kind:"cancelled subagent status"
        (fun cancelled_at usage -> cancelled ~cancelled_at ?usage ())
      |> Jsont.Object.mem "cancelled_at" Time.jsont ~enc:(function
        | Cancelled { cancelled_at; _ } -> cancelled_at
        | Queued | Running _ | Blocked _ | Completed _ | Failed _ ->
            assert false)
      |> usage_mem ~enc:(function
        | Cancelled { usage; _ } -> usage
        | Queued | Running _ | Blocked _ | Completed _ | Failed _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "cancelled" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [
          queued_case;
          running_case;
          blocked_case;
          completed_case;
          failed_case;
          cancelled_case;
        ]
    in
    let enc_case = function
      | Queued as status -> Jsont.Object.Case.value queued_case status
      | Running _ as status -> Jsont.Object.Case.value running_case status
      | Blocked _ as status -> Jsont.Object.Case.value blocked_case status
      | Completed _ as status -> Jsont.Object.Case.value completed_case status
      | Failed _ as status -> Jsont.Object.Case.value failed_case status
      | Cancelled _ as status -> Jsont.Object.Case.value cancelled_case status
    in
    Jsont.Object.map ~kind:"subagent status" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  child : Spice_session.Id.t;
  parent : Spice_session.Id.t;
  parent_turn : Spice_session.Turn.Id.t;
  parent_call_id : string;
  spawn : Subagent.Spawn.t;
  depth : int;
  status : Status.t;
  created_at : Time.t;
}

let check_depth depth =
  if depth < 0 then
    Error ("subagent depth must not be negative, got " ^ string_of_int depth)
  else Ok ()

let check_status_time ~created_at status =
  Status_lifecycle.check_snapshot_time ~created_at
    ~transition_time:Status.transition_time
    ~error:(fun status ->
      "subagent " ^ Status.to_string status
      ^ " time must not be before creation time")
    status

let make_with_status ~child ~parent ~parent_turn ~parent_call_id ~spawn ~depth
    ~status ~created_at () =
  let* () =
    check_non_empty "subagent parent tool call id must not be empty"
      parent_call_id
  in
  let* () = check_depth depth in
  let* () = check_status_time ~created_at status in
  Ok
    {
      child;
      parent;
      parent_turn;
      parent_call_id;
      spawn;
      depth;
      status;
      created_at;
    }

let make ~child ~parent ~parent_turn ~parent_call_id ~spawn ~depth ~created_at
    () =
  make_with_status ~child ~parent ~parent_turn ~parent_call_id ~spawn ~depth
    ~status:Status.queued ~created_at ()

let child t = t.child
let parent t = t.parent
let parent_turn t = t.parent_turn
let parent_call_id t = t.parent_call_id
let spawn t = t.spawn
let role t = Subagent.Spawn.role t.spawn
let task t = Subagent.Spawn.task t.spawn
let depth t = t.depth
let status t = t.status
let created_at t = t.created_at

let updated_at t =
  Option.value (Status.transition_time t.status) ~default:t.created_at

let invalid_transition action t =
  Error
    ("cannot " ^ action ^ " subagent "
    ^ Spice_session.Id.to_string t.child
    ^ " while it is " ^ Status.to_string t.status)

let check_transition_time t status =
  match Status.transition_time status with
  | None -> Error "subagent transition status has no timestamp"
  | Some transition_at ->
      Status_lifecycle.check_transition_time ~updated_at:(updated_at t)
        ~transition_at
        ~error:
          ("subagent " ^ Status.to_string status
         ^ " time must not be before its previous transition")

let set_status action status t =
  let* () = check_transition_time t status in
  match (t.status, status) with
  | Status.Queued, Status.Running _ -> Ok { t with status }
  | (Status.Running _ | Status.Blocked _), Status.Blocked _ ->
      Ok { t with status }
  | ( (Status.Running _ | Status.Blocked _),
      (Status.Completed _ | Status.Failed _ | Status.Cancelled _) ) ->
      Ok { t with status }
  | Status.Queued, (Status.Failed _ | Status.Cancelled _) ->
      Ok { t with status }
  | Status.Queued, (Status.Queued | Status.Blocked _ | Status.Completed _) ->
      invalid_transition action t
  | (Status.Completed _ | Status.Failed _ | Status.Cancelled _), _ ->
      invalid_transition action t
  | (Status.Running _ | Status.Blocked _), (Status.Queued | Status.Running _) ->
      invalid_transition action t

let start ~started_at t = set_status "start" (Status.running ~started_at) t

let block ~blocked_at ~blocker t =
  let* status = Status.blocked ~blocked_at ~blocker in
  set_status "block" status t

let complete ~completed_at ~summary ?usage t =
  let* status = Status.completed ~completed_at ~summary ?usage () in
  set_status "complete" status t

let fail ~failed_at ~message ?usage t =
  let* status = Status.failed ~failed_at ~message ?usage () in
  set_status "fail" status t

let cancel ~cancelled_at ?usage t =
  set_status "cancel" (Status.cancelled ~cancelled_at ?usage ()) t

(* The one deliberate backward edge in the otherwise forward-only lifecycle:
   a message resumed the settled child session. Bypasses [set_status], whose
   lattice is forward-only by design. *)
let resume ~resumed_at t =
  let status = Status.running ~started_at:resumed_at in
  let* () = check_transition_time t status in
  match t.status with
  | Status.Queued | Status.Running _ -> invalid_transition "resume" t
  | Status.Blocked _ | Status.Completed _ | Status.Failed _ | Status.Cancelled _
    ->
      Ok { t with status }

let usage t =
  match t.status with
  | Status.Queued | Status.Running _ | Status.Blocked _ -> None
  | Status.Completed { usage; _ }
  | Status.Failed { usage; _ }
  | Status.Cancelled { usage; _ } ->
      usage

let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf
    "@[<hov>{ child = %a; parent = %a; parent_turn = %a; role = %a; depth = \
     %d; status = %a }@]"
    Spice_session.Id.pp t.child Spice_session.Id.pp t.parent
    Spice_session.Turn.Id.pp t.parent_turn Subagent.Role.pp (role t) t.depth
    Status.pp t.status

let jsont =
  Jsont.Object.map ~kind:"subagent run"
    (fun
      child parent parent_turn parent_call_id spawn depth status created_at ->
      Decode.or_error
        (make_with_status ~child ~parent ~parent_turn ~parent_call_id ~spawn
           ~depth ~status ~created_at ()))
  |> Jsont.Object.mem "child" Spice_session.Id.jsont ~enc:child
  |> Jsont.Object.mem "parent" Spice_session.Id.jsont ~enc:parent
  |> Jsont.Object.mem "parent_turn" Spice_session.Turn.Id.jsont ~enc:parent_turn
  |> Jsont.Object.mem "parent_call_id" Jsont.string ~enc:parent_call_id
  |> Jsont.Object.mem "spawn" Subagent.Spawn.jsont ~enc:spawn
  |> Jsont.Object.mem "depth" Jsont.int ~enc:depth
  |> Jsont.Object.mem "status" Status.jsont ~enc:status
  |> Jsont.Object.mem "created_at" Time.jsont ~enc:created_at
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
