(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Time = Spice_session.Time
open Result.Syntax

module Id = struct
  type t = string

  let of_string id =
    if String.is_empty id then Error "plan id must not be empty" else Ok id

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t

  let jsont =
    Jsont.map ~kind:"plan id"
      ~dec:(fun id -> Decode.or_error (of_string id))
      ~enc:to_string Jsont.string
end

module Source = struct
  type t = {
    session : Spice_session.Id.t;
    turn : Spice_session.Turn.Id.t;
    tool_call_id : string option;
  }

  let make ~session ~turn ?tool_call_id () =
    match tool_call_id with
    | Some "" -> Error "plan source tool call id must not be empty"
    | Some _ | None -> Ok { session; turn; tool_call_id }

  let session t = t.session
  let turn t = t.turn
  let tool_call_id t = t.tool_call_id

  let equal a b =
    Spice_session.Id.equal a.session b.session
    && Spice_session.Turn.Id.equal a.turn b.turn
    && Option.equal String.equal a.tool_call_id b.tool_call_id

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ session = %a; turn = %a; tool_call_id = %a }@]"
      Spice_session.Id.pp t.session Spice_session.Turn.Id.pp t.turn
      (Format.pp_print_option Format.pp_print_string)
      t.tool_call_id

  let jsont =
    Jsont.Object.map ~kind:"plan source" (fun session turn tool_call_id ->
        Decode.or_error (make ~session ~turn ?tool_call_id ()))
    |> Jsont.Object.mem "session" Spice_session.Id.jsont ~enc:session
    |> Jsont.Object.mem "turn" Spice_session.Turn.Id.jsont ~enc:turn
    |> Jsont.Object.opt_mem "tool_call_id" Jsont.string ~enc:tool_call_id
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Status = struct
  type t =
    | Proposed
    | Approved of { approved_at : Time.t }
    | Rejected of { rejected_at : Time.t; reason : string option }
    | Superseded of { superseded_at : Time.t; by : Id.t }

  let proposed = Proposed
  let approved ~approved_at = Approved { approved_at }

  let rejected ~rejected_at ?reason () =
    match reason with
    | Some "" -> Error "plan rejection reason must not be empty"
    | Some _ | None -> Ok (Rejected { rejected_at; reason })

  let superseded ~superseded_at ~by = Superseded { superseded_at; by }
  let is_proposed = function Proposed -> true | _ -> false
  let is_approved = function Approved _ -> true | _ -> false
  let is_rejected = function Rejected _ -> true | _ -> false
  let is_superseded = function Superseded _ -> true | _ -> false

  let transition_time = function
    | Proposed -> None
    | Approved { approved_at } -> Some approved_at
    | Rejected { rejected_at; _ } -> Some rejected_at
    | Superseded { superseded_at; _ } -> Some superseded_at

  let to_string = function
    | Proposed -> "proposed"
    | Approved _ -> "approved"
    | Rejected _ -> "rejected"
    | Superseded _ -> "superseded"

  let equal a b = a = b

  let pp ppf = function
    | Proposed -> Format.pp_print_string ppf "proposed"
    | Approved { approved_at } ->
        Format.fprintf ppf "approved(%a)" Time.pp approved_at
    | Rejected { rejected_at; reason = None } ->
        Format.fprintf ppf "rejected(%a)" Time.pp rejected_at
    | Rejected { rejected_at; reason = Some reason } ->
        Format.fprintf ppf "rejected(%a, %S)" Time.pp rejected_at reason
    | Superseded { superseded_at; by } ->
        Format.fprintf ppf "superseded(%a, by=%a)" Time.pp superseded_at Id.pp
          by

  let jsont =
    let proposed_case =
      Jsont.Object.map ~kind:"proposed plan status" Proposed
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "proposed" ~dec:Fun.id
    in
    let approved_case =
      Jsont.Object.map ~kind:"approved plan status" (fun approved_at ->
          Approved { approved_at })
      |> Jsont.Object.mem "approved_at" Time.jsont ~enc:(function
        | Approved { approved_at } -> approved_at
        | Proposed | Rejected _ | Superseded _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "approved" ~dec:Fun.id
    in
    let rejected_case =
      Jsont.Object.map ~kind:"rejected plan status" (fun rejected_at reason ->
          Decode.or_error (rejected ~rejected_at ?reason ()))
      |> Jsont.Object.mem "rejected_at" Time.jsont ~enc:(function
        | Rejected { rejected_at; _ } -> rejected_at
        | Proposed | Approved _ | Superseded _ -> assert false)
      |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(function
        | Rejected { reason; _ } -> reason
        | Proposed | Approved _ | Superseded _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "rejected" ~dec:Fun.id
    in
    let superseded_case =
      Jsont.Object.map ~kind:"superseded plan status" (fun superseded_at by ->
          Superseded { superseded_at; by })
      |> Jsont.Object.mem "superseded_at" Time.jsont ~enc:(function
        | Superseded { superseded_at; _ } -> superseded_at
        | Proposed | Approved _ | Rejected _ -> assert false)
      |> Jsont.Object.mem "by" Id.jsont ~enc:(function
        | Superseded { by; _ } -> by
        | Proposed | Approved _ | Rejected _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "superseded" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ proposed_case; approved_case; rejected_case; superseded_case ]
    in
    let enc_case = function
      | Proposed as status -> Jsont.Object.Case.value proposed_case status
      | Approved _ as status -> Jsont.Object.Case.value approved_case status
      | Rejected _ as status -> Jsont.Object.Case.value rejected_case status
      | Superseded _ as status -> Jsont.Object.Case.value superseded_case status
    in
    Jsont.Object.map ~kind:"plan status" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  id : Id.t;
  source : Source.t;
  title : string option;
  body : string;
  status : Status.t;
  created_at : Time.t;
}

let check_title = function
  | Some "" -> Error "plan title must not be empty"
  | Some _ | None -> Ok ()

let check_body = function
  | "" -> Error "plan body must not be empty"
  | _ -> Ok ()

let check_status_time ~created_at status =
  Status_lifecycle.check_snapshot_time ~created_at
    ~transition_time:Status.transition_time
    ~error:(fun status ->
      "plan " ^ Status.to_string status
      ^ " must not be before plan creation time")
    status

let check_replacement id by =
  if Id.equal id by then
    Error ("plan " ^ Id.to_string id ^ " cannot supersede itself")
  else Ok ()

let check_status_id id = function
  | Status.Superseded { by; _ } -> check_replacement id by
  | Status.Proposed | Status.Approved _ | Status.Rejected _ -> Ok ()

(* The single validation path shared by [propose] and the codec, which is why
   the codec can decode any stored lifecycle status without re-checking. *)
let make ~id ~source ?title ~body ~status ~created_at () =
  let* () = check_title title in
  let* () = check_body body in
  let* () = check_status_id id status in
  let* () = check_status_time ~created_at status in
  Ok { id; source; title; body; status; created_at }

let propose ~id ~source ?title ~body ~created_at () =
  make ~id ~source ?title ~body ~status:Status.proposed ~created_at ()

let id t = t.id
let source t = t.source
let title t = t.title
let body t = t.body
let status t = t.status
let created_at t = t.created_at

let updated_at t =
  Option.value (Status.transition_time t.status) ~default:t.created_at

let invalid_transition action t =
  Error
    ("cannot " ^ action ^ " plan " ^ Id.to_string t.id ^ " while it is "
   ^ Status.to_string t.status)

let check_transition_time t status =
  match Status.transition_time status with
  | None -> Error "plan transition status has no timestamp"
  | Some transition_at ->
      Status_lifecycle.check_transition_time ~updated_at:(updated_at t)
        ~transition_at
        ~error:
          ("plan " ^ Status.to_string status
         ^ " time must not be before its previous transition")

let approve ~approved_at t =
  match t.status with
  | Status.Proposed ->
      let status = Status.approved ~approved_at in
      let* () = check_transition_time t status in
      Ok { t with status }
  | Status.Approved _ | Status.Rejected _ | Status.Superseded _ ->
      invalid_transition "approve" t

let reject ~rejected_at ?reason t =
  match t.status with
  | Status.Proposed ->
      let* status = Status.rejected ~rejected_at ?reason () in
      let* () = check_transition_time t status in
      Ok { t with status }
  | Status.Approved _ | Status.Rejected _ | Status.Superseded _ ->
      invalid_transition "reject" t

let supersede ~superseded_at ~by t =
  let* () = check_replacement t.id by in
  match t.status with
  | Status.Superseded _ -> invalid_transition "supersede" t
  | Status.Proposed | Status.Approved _ | Status.Rejected _ ->
      let status = Status.superseded ~superseded_at ~by in
      let* () = check_transition_time t status in
      Ok { t with status }

let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf
    "@[<hov>{ id = %a; source = %a; title = %a; status = %a; created_at = %a \
     }@]"
    Id.pp t.id Source.pp t.source
    (Format.pp_print_option Format.pp_print_string)
    t.title Status.pp t.status Time.pp t.created_at

let jsont =
  Jsont.Object.map ~kind:"workflow plan"
    (fun id source title body status created_at ->
      Decode.or_error (make ~id ~source ?title ~body ~status ~created_at ()))
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "source" Source.jsont ~enc:source
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:title
  |> Jsont.Object.mem "body" Jsont.string ~enc:body
  |> Jsont.Object.mem "status" Status.jsont ~enc:status
  |> Jsont.Object.mem "created_at" Time.jsont ~enc:created_at
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

module Proposal = struct
  type t = { id : Id.t; title : string option; body : string }

  let make ~id ?title ~body () =
    let* () = check_title title in
    let* () = check_body body in
    Ok { id; title; body }

  let id (t : t) = t.id
  let title (t : t) = t.title
  let body (t : t) = t.body
  let equal a b = a = b

  let pp ppf (t : t) =
    Format.fprintf ppf "@[<hov>{ id = %a; title = %a }@]" Id.pp t.id
      (Format.pp_print_option Format.pp_print_string)
      t.title

  let jsont =
    Jsont.Object.map ~kind:"plan proposal" (fun id title body ->
        Decode.or_error (make ~id ?title ~body ()))
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.opt_mem "title" Jsont.string ~enc:title
    |> Jsont.Object.mem "body" Jsont.string ~enc:body
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_list values = Jsont.Json.list values

let non_empty_string_schema =
  json_obj
    [
      ("type", Jsont.Json.string "string"); ("minLength", Jsont.Json.int 1);
    ]

let name = "propose_plan"

let tool_schema =
  json_obj
    [
      ("type", Jsont.Json.string "object");
      ( "properties",
        json_obj
          [
            ("id", non_empty_string_schema);
            ("title", non_empty_string_schema);
            ("body", non_empty_string_schema);
          ] );
      ( "required",
        json_list [ Jsont.Json.string "id"; Jsont.Json.string "body" ] );
      ("additionalProperties", Jsont.Json.bool false);
    ]

let tool =
  Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.propose_plan
    ~input_schema:tool_schema ()

let decode call =
  let actual = Spice_llm.Tool.Call.name call in
  if not (String.equal actual name) then
    Error ("expected " ^ name ^ " call, got " ^ actual)
  else Jsont.Json.decode Proposal.jsont (Spice_llm.Tool.Call.input call)

(* Resolution *)

module Decision = struct
  type t = Approve | Reject of { reason : string option }

  let equal a b = a = b

  let pp ppf = function
    | Approve -> Format.pp_print_string ppf "approve"
    | Reject { reason = None } -> Format.pp_print_string ppf "reject"
    | Reject { reason = Some reason } -> Format.fprintf ppf "reject(%S)" reason
end
