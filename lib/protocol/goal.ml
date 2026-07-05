(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Time = Spice_session.Time
open Result.Syntax

module Id = struct
  type t = string

  let of_string id =
    if String.is_empty id then Error "goal id must not be empty" else Ok id

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t

  let jsont =
    Jsont.map ~kind:"goal id"
      ~dec:(fun id -> Decode.or_error (of_string id))
      ~enc:to_string Jsont.string
end

let check_reason = function
  | Some "" -> Error "goal blocked reason must not be empty"
  | Some _ | None -> Ok ()

let check_summary = function
  | Some "" -> Error "goal summary must not be empty"
  | Some _ | None -> Ok ()

module Status = struct
  type t =
    | Active
    | Paused
    | Blocked of { reason : string option }
    | Budget_limited
    | Completed of { summary : string option }
    | Cleared

  let active = Active
  let paused = Paused

  let blocked ?reason () =
    let* () = check_reason reason in
    Ok (Blocked { reason })

  let budget_limited = Budget_limited

  let completed ?summary () =
    let* () = check_summary summary in
    Ok (Completed { summary })

  let cleared = Cleared

  let is_terminal = function
    | Completed _ | Cleared -> true
    | Active | Paused | Blocked _ | Budget_limited -> false

  let to_string = function
    | Active -> "active"
    | Paused -> "paused"
    | Blocked _ -> "blocked"
    | Budget_limited -> "budget_limited"
    | Completed _ -> "completed"
    | Cleared -> "cleared"

  let equal a b = a = b

  let pp ppf = function
    | Blocked { reason = Some reason } ->
        Format.fprintf ppf "blocked(%S)" reason
    | Completed { summary = Some summary } ->
        Format.fprintf ppf "completed(%S)" summary
    | status -> Format.pp_print_string ppf (to_string status)

  let jsont =
    let active_case =
      Jsont.Object.map ~kind:"active goal status" Active
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "active" ~dec:Fun.id
    in
    let paused_case =
      Jsont.Object.map ~kind:"paused goal status" Paused
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "paused" ~dec:Fun.id
    in
    let blocked_case =
      Jsont.Object.map ~kind:"blocked goal status" (fun reason ->
          Decode.or_error (blocked ?reason ()))
      |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(function
        | Blocked { reason } -> reason
        | Active | Paused | Budget_limited | Completed _ | Cleared ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "blocked" ~dec:Fun.id
    in
    let budget_limited_case =
      Jsont.Object.map ~kind:"budget-limited goal status" Budget_limited
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "budget_limited" ~dec:Fun.id
    in
    let completed_case =
      Jsont.Object.map ~kind:"completed goal status" (fun summary ->
          Decode.or_error (completed ?summary ()))
      |> Jsont.Object.opt_mem "summary" Jsont.string ~enc:(function
        | Completed { summary } -> summary
        | Active | Paused | Blocked _ | Budget_limited | Cleared -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "completed" ~dec:Fun.id
    in
    let cleared_case =
      Jsont.Object.map ~kind:"cleared goal status" Cleared
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "cleared" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [
          active_case;
          paused_case;
          blocked_case;
          budget_limited_case;
          completed_case;
          cleared_case;
        ]
    in
    let enc_case = function
      | Active as status -> Jsont.Object.Case.value active_case status
      | Paused as status -> Jsont.Object.Case.value paused_case status
      | Blocked _ as status -> Jsont.Object.Case.value blocked_case status
      | Budget_limited as status ->
          Jsont.Object.Case.value budget_limited_case status
      | Completed _ as status -> Jsont.Object.Case.value completed_case status
      | Cleared as status -> Jsont.Object.Case.value cleared_case status
    in
    Jsont.Object.map ~kind:"goal status" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  id : Id.t;
  session : Spice_session.Id.t;
  objective : string;
  status : Status.t;
  token_budget : int option;
  tokens_used : int;
  time_used_ms : int;
  continuation_turns : int;
  created_at : Time.t;
  updated_at : Time.t;
}

let check_objective = function
  | "" -> Error "goal objective must not be empty"
  | _ -> Ok ()

let check_budget = function
  | Some budget when budget <= 0 -> Error "goal token budget must be positive"
  | Some _ | None -> Ok ()

let check_counter name count =
  if count < 0 then Error ("goal " ^ name ^ " must not be negative") else Ok ()

let check_updated_at ~created_at updated_at =
  if Time.compare updated_at created_at < 0 then
    Error "goal update time must not be before goal creation time"
  else Ok ()

(* The single validation path shared by [set] and the codec, which is why the
   codec can decode any stored lifecycle status without re-checking. *)
let make ~id ~session ~objective ~status ?token_budget ~tokens_used
    ~time_used_ms ~continuation_turns ~created_at ~updated_at () =
  let* () = check_objective objective in
  let* () = check_budget token_budget in
  let* () = check_counter "tokens used" tokens_used in
  let* () = check_counter "time used" time_used_ms in
  let* () = check_counter "continuation turns" continuation_turns in
  let* () = check_updated_at ~created_at updated_at in
  Ok
    {
      id;
      session;
      objective;
      status;
      token_budget;
      tokens_used;
      time_used_ms;
      continuation_turns;
      created_at;
      updated_at;
    }

let set ~id ~session ~objective ?token_budget ~created_at () =
  make ~id ~session ~objective ~status:Status.active ?token_budget
    ~tokens_used:0 ~time_used_ms:0 ~continuation_turns:0 ~created_at
    ~updated_at:created_at ()

let id t = t.id
let session t = t.session
let objective t = t.objective
let status t = t.status
let token_budget t = t.token_budget
let tokens_used t = t.tokens_used

let remaining_tokens t =
  Option.map (fun budget -> Int.max 0 (budget - t.tokens_used)) t.token_budget

let time_used_ms t = t.time_used_ms
let continuation_turns t = t.continuation_turns
let created_at t = t.created_at
let updated_at t = t.updated_at
let is_unfinished t = not (Status.is_terminal t.status)
let is_active t = match t.status with Status.Active -> true | _ -> false

let may_update t =
  match t.status with
  | Status.Active | Status.Budget_limited -> true
  | Status.Paused | Status.Blocked _ | Status.Completed _ | Status.Cleared ->
      false

let invalid_transition action t =
  Error
    ("cannot " ^ action ^ " goal " ^ Id.to_string t.id ^ " while it is "
   ^ Status.to_string t.status)

let transition ~at status t =
  let* () = check_updated_at ~created_at:t.created_at at in
  Ok { t with status; updated_at = at }

let pause ~paused_at t =
  match t.status with
  | Status.Active -> transition ~at:paused_at Status.paused t
  | Status.Paused | Status.Blocked _ | Status.Budget_limited
  | Status.Completed _ | Status.Cleared ->
      invalid_transition "pause" t

let resume ~resumed_at ?token_budget t =
  match t.status with
  | Status.Paused | Status.Blocked _ | Status.Budget_limited ->
      let* () = check_budget token_budget in
      let token_budget =
        Option.fold ~none:t.token_budget ~some:Option.some token_budget
      in
      let* t = transition ~at:resumed_at Status.active t in
      Ok { t with token_budget }
  | Status.Active | Status.Completed _ | Status.Cleared ->
      invalid_transition "resume" t

let edit ~objective ~edited_at t =
  if Status.is_terminal t.status then invalid_transition "edit" t
  else
    let* () = check_objective objective in
    let* t = transition ~at:edited_at t.status t in
    Ok { t with objective }

let clear ~cleared_at t =
  if Status.is_terminal t.status then invalid_transition "clear" t
  else transition ~at:cleared_at Status.cleared t

let complete ~completed_at ?summary t =
  match t.status with
  | Status.Active | Status.Budget_limited ->
      let* status = Status.completed ?summary () in
      transition ~at:completed_at status t
  | Status.Paused | Status.Blocked _ | Status.Completed _ | Status.Cleared ->
      invalid_transition "complete" t

let block ~blocked_at ?reason t =
  match t.status with
  | Status.Active | Status.Budget_limited ->
      let* status = Status.blocked ?reason () in
      transition ~at:blocked_at status t
  | Status.Paused | Status.Blocked _ | Status.Completed _ | Status.Cleared ->
      invalid_transition "block" t

let limit_budget ~limited_at t =
  match (t.status, t.token_budget) with
  | Status.Active, Some _ -> transition ~at:limited_at Status.budget_limited t
  | Status.Active, None ->
      Error
        ("cannot budget-limit goal " ^ Id.to_string t.id
       ^ " without a token budget")
  | ( ( Status.Paused | Status.Blocked _ | Status.Budget_limited
      | Status.Completed _ | Status.Cleared ),
      _ ) ->
      invalid_transition "budget-limit" t

let record_turn ~at ~tokens ~active_ms ~continuation t =
  let* () = check_counter "turn tokens" tokens in
  let* () = check_counter "turn time" active_ms in
  let* t = transition ~at t.status t in
  Ok
    {
      t with
      tokens_used = t.tokens_used + tokens;
      time_used_ms = t.time_used_ms + active_ms;
      continuation_turns = (t.continuation_turns + if continuation then 1 else 0);
    }

let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf
    "@[<hov>{ id = %a; session = %a; objective = %S; status = %a; token_budget \
     = %a; tokens_used = %d; time_used_ms = %d; continuation_turns = %d; \
     created_at = %a; updated_at = %a }@]"
    Id.pp t.id Spice_session.Id.pp t.session t.objective Status.pp t.status
    (Format.pp_print_option Format.pp_print_int)
    t.token_budget t.tokens_used t.time_used_ms t.continuation_turns Time.pp
    t.created_at Time.pp t.updated_at

let jsont =
  Jsont.Object.map ~kind:"workflow goal"
    (fun
      id
      session
      objective
      status
      token_budget
      tokens_used
      time_used_ms
      continuation_turns
      created_at
      updated_at
    ->
      Decode.or_error
        (make ~id ~session ~objective ~status ?token_budget ~tokens_used
           ~time_used_ms ~continuation_turns ~created_at ~updated_at ()))
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "session" Spice_session.Id.jsont ~enc:session
  |> Jsont.Object.mem "objective" Jsont.string ~enc:objective
  |> Jsont.Object.mem "status" Status.jsont ~enc:status
  |> Jsont.Object.opt_mem "token_budget" Jsont.int ~enc:token_budget
  |> Jsont.Object.mem "tokens_used" Jsont.int ~enc:tokens_used
  |> Jsont.Object.mem "time_used_ms" Jsont.int ~enc:time_used_ms
  |> Jsont.Object.mem "continuation_turns" Jsont.int ~enc:continuation_turns
  |> Jsont.Object.mem "created_at" Time.jsont ~enc:created_at
  |> Jsont.Object.mem "updated_at" Time.jsont ~enc:updated_at
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

(* Turn origin *)

let turn_origin = "goal"

let is_continuation_turn turn =
  match Spice_session.Turn.origin turn with
  | Some origin -> String.equal origin turn_origin
  | None -> false

(* Host tool *)

module Update = struct
  type t =
    | Complete of { summary : string option }
    | Blocked of { summary : string option }

  let make ~status ?summary () =
    let* () = check_summary summary in
    match status with
    | "complete" -> Ok (Complete { summary })
    | "blocked" -> Ok (Blocked { summary })
    | status ->
        Error
          ("unknown goal update status: " ^ status
         ^ "; expected \"complete\" or \"blocked\"")

  let summary = function Complete { summary } | Blocked { summary } -> summary
  let to_string = function Complete _ -> "complete" | Blocked _ -> "blocked"
  let equal a b = a = b

  let pp ppf t =
    match summary t with
    | None -> Format.pp_print_string ppf (to_string t)
    | Some summary -> Format.fprintf ppf "%s(%S)" (to_string t) summary

  let jsont =
    Jsont.Object.map ~kind:"update_goal input" (fun status summary ->
        Decode.or_error (make ~status ?summary ()))
    |> Jsont.Object.mem "status" Jsont.string ~enc:to_string
    |> Jsont.Object.opt_mem "summary" Jsont.string ~enc:summary
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let apply ~now update t =
  match (update : Update.t) with
  | Update.Complete { summary } -> complete ~completed_at:now ?summary t
  | Update.Blocked { summary } -> block ~blocked_at:now ?reason:summary t

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_list values = Jsont.Json.list values
let name = "update_goal"

let tool_schema =
  json_obj
    [
      ("type", Jsont.Json.string "object");
      ( "properties",
        json_obj
          [
            ( "status",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ( "enum",
                    json_list
                      [
                        Jsont.Json.string "complete";
                        Jsont.Json.string "blocked";
                      ] );
                  ( "description",
                    Jsont.Json.string
                      "The goal's final state: complete only when every \
                       requirement is verified against current evidence; \
                       blocked only at a real, repeated impasse." );
                ] );
            ( "summary",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ("minLength", Jsont.Json.int 1);
                  ( "description",
                    Jsont.Json.string
                      "One or two sentences: what was delivered, or the exact \
                       blocker and what would unblock it." );
                ] );
          ] );
      ("required", json_list [ Jsont.Json.string "status" ]);
      ("additionalProperties", Jsont.Json.bool false);
    ]

let tool =
  Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.update_goal
    ~input_schema:tool_schema ()

let decode call =
  let actual = Spice_llm.Tool.Call.name call in
  if not (String.equal actual name) then
    Error ("expected " ^ name ^ " call, got " ^ actual)
  else Jsont.Json.decode Update.jsont (Spice_llm.Tool.Call.input call)
