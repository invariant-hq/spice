(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Id = Id
module Time = Time
module Revision = Revision
module Metadata = Metadata
module Turn = Turn
module Permission = Permission
module Tool_claim = Tool_claim
module Compaction = Compaction
module Waiting = Waiting
module Event = Event
module State = State
module Anchor = Anchor

module Error = struct
  type t =
    | State of State.Error.t
    | Replay of State.Replay_error.t
    | Archived
    | Deleted
    | Active_turn of Turn.Id.t
    | Unknown_turn of Turn.Id.t
    | Turn_not_finished of Turn.Id.t

  let message = function
    | State error -> State.Error.message error
    | Replay error -> State.Replay_error.message error
    | Archived -> "session is archived"
    | Deleted -> "session has been deleted"
    | Active_turn turn ->
        Format.asprintf "turn is still active: %a" Turn.Id.pp turn
    | Unknown_turn turn ->
        Format.asprintf "turn is not in the session: %a" Turn.Id.pp turn
    | Turn_not_finished turn ->
        Format.asprintf "turn has not finished: %a" Turn.Id.pp turn

  let pp ppf t = Format.pp_print_string ppf (message t)
end

type t = {
  id : Id.t;
  metadata : Metadata.t;
  events_rev : Event.t list;
  state : State.t;
}

type session = t

let make ~id ~metadata ~events =
  match State.of_events events with
  | Error error -> Error (Error.Replay error)
  | Ok state -> Ok { id; metadata; events_rev = List.rev events; state }

let create ~id ?title ~cwd ~created_at () =
  {
    id;
    metadata = Metadata.make ?title ~cwd ~created_at ~updated_at:created_at ();
    events_rev = [];
    state = State.empty;
  }

let id t = t.id
let metadata t = t.metadata
let events t = List.rev t.events_rev
let state t = t.state

let require_not_deleted t =
  if Metadata.is_deleted t.metadata then Error Error.Deleted else Ok ()

let require_active_status t =
  match Metadata.status t.metadata with
  | Metadata.Status.Active -> Ok ()
  | Metadata.Status.Archived -> Error Error.Archived
  | Metadata.Status.Deleted -> Error Error.Deleted

let require_no_active_turn t =
  match State.active_turn_id t.state with
  | None -> Ok ()
  | Some turn -> Error (Error.Active_turn turn)

let append event t =
  match require_active_status t with
  | Error _ as error -> error
  | Ok () -> (
      match State.apply event t.state with
      | Error error -> Error (Error.State error)
      | Ok state -> Ok { t with events_rev = event :: t.events_rev; state })

let append_all events t =
  match events with
  | [] -> Ok t
  | _ -> (
      match require_active_status t with
      | Error _ as error -> error
      | Ok () -> (
          match State.apply_all events t.state with
          | Error error ->
              let by = List.length t.events_rev in
              Error (Error.Replay (State.Replay_error.shift ~by error))
          | Ok state ->
              Ok
                {
                  t with
                  events_rev = List.rev_append events t.events_rev;
                  state;
                }))

let set_title title t =
  { t with metadata = Metadata.with_title title t.metadata }

let touch time t = { t with metadata = Metadata.touch time t.metadata }

let archive t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () ->
          Ok
            {
              t with
              metadata =
                Metadata.with_status Metadata.Status.Archived t.metadata;
            })

let restore t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () ->
      Ok
        {
          t with
          metadata = Metadata.with_status Metadata.Status.Active t.metadata;
        }

let delete t =
  if Metadata.is_deleted t.metadata then Ok t
  else
    match require_no_active_turn t with
    | Error _ as error -> error
    | Ok () ->
        Ok
          {
            t with
            metadata = Metadata.with_status Metadata.Status.Deleted t.metadata;
          }

let fork ~id ?title ~cwd ~created_at t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () ->
          let forked_from =
            Metadata.Forked_from.make ~parent:t.id
              ~copied_events:(List.length t.events_rev)
          in
          let metadata =
            Metadata.make ?title ~forked_from ~cwd ~created_at
              ~updated_at:created_at ()
          in
          Ok { id; metadata; events_rev = t.events_rev; state = t.state })

let turn_started_index events turn_id =
  let rec loop i = function
    | [] -> None
    | Event.Turn_started turn :: _ when Turn.Id.equal (Turn.id turn) turn_id ->
        Some i
    | _ :: events -> loop (i + 1) events
  in
  loop 0 events

let turn_finished_index events turn_id =
  let rec loop i = function
    | [] -> None
    | Event.Turn_finished { turn; _ } :: _ when Turn.Id.equal turn turn_id ->
        Some i
    | _ :: events -> loop (i + 1) events
  in
  loop 0 events

let resolve_anchor_in events anchor t =
  let turn_id = Anchor.turn anchor in
  match Anchor.edge anchor with
  | Anchor.Before -> (
      match turn_started_index events turn_id with
      | Some index -> Ok index
      | None -> Error (Error.Unknown_turn turn_id))
  | Anchor.After -> (
      match State.turn turn_id t.state with
      | None -> Error (Error.Unknown_turn turn_id)
      | Some _ -> (
          match turn_finished_index events turn_id with
          | Some index -> Ok (index + 1)
          | None -> Error (Error.Turn_not_finished turn_id)))

let resolve_anchor anchor t = resolve_anchor_in (events t) anchor t

let dropped_turns anchor t =
  let events = events t in
  match resolve_anchor_in events anchor t with
  | Error _ as error -> error
  | Ok cut ->
      let rec loop i acc = function
        | [] -> List.rev acc
        | Event.Turn_started turn :: events ->
            let acc = if i >= cut then Turn.id turn :: acc else acc in
            loop (i + 1) acc events
        | _ :: events -> loop (i + 1) acc events
      in
      Ok (loop 0 [] events)

let rewind ~id ?title ~cwd ~created_at anchor t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () -> (
          let events = events t in
          match resolve_anchor_in events anchor t with
          | Error _ as error -> error
          | Ok copied_events ->
              let events = List.take copied_events events in
              let forked_from =
                Metadata.Forked_from.make ~parent:t.id ~copied_events
              in
              let metadata =
                Metadata.make ?title ~forked_from ~cwd ~created_at
                  ~updated_at:created_at ()
              in
              make ~id ~metadata ~events))

let jsont =
  let version = 1 in
  let make version' id metadata events =
    if not (Int.equal version version') then
      decode_error "unsupported session version";
    match make ~id ~metadata ~events with
    | Ok session -> session
    | Error error -> decode_error (Error.message error)
  in
  Jsont.Object.map ~kind:"session" make
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> version)
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "metadata" Metadata.jsont ~enc:metadata
  |> Jsont.Object.mem "events" (Jsont.list Event.jsont) ~enc:events
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

module Metrics = struct
  module Tool_name_map = Map.Make (String)

  type t = {
    usage : Spice_llm.Usage.t;
    responses : int;
    turns : int;
    tool_calls : int;
    tool_failures : int;
    tool_rejections : int;
    tool_calls_by_name : (string * int) list;
    permission_denials : int;
  }

  let invalid fn message = invalid_arg' "Spice_session.Metrics" fn message

  let check_non_negative fn field value =
    if value < 0 then invalid fn (field ^ " must be non-negative")

  let add_checked fn a b =
    if a > max_int - b then invalid fn "overflow" else a + b

  let incr_checked fn value = add_checked fn value 1

  let check_tool_calls_by_name fn entries =
    let rec loop previous = function
      | [] -> ()
      | (name, count) :: rest ->
          if String.is_empty name then
            invalid fn "tool call names must not be empty";
          if count <= 0 then
            invalid fn "tool call counts by name must be positive";
          begin match previous with
          | None -> ()
          | Some previous ->
              if String.compare previous name >= 0 then
                invalid fn "tool call counts by name must be sorted and unique"
          end;
          loop (Some name) rest
    in
    loop None entries

  let make ~usage ~responses ~turns ~tool_calls ~tool_failures ~tool_rejections
      ~tool_calls_by_name ~permission_denials =
    check_non_negative "make" "responses" responses;
    check_non_negative "make" "turns" turns;
    check_non_negative "make" "tool_calls" tool_calls;
    check_non_negative "make" "tool_failures" tool_failures;
    check_non_negative "make" "tool_rejections" tool_rejections;
    check_non_negative "make" "permission_denials" permission_denials;
    if tool_failures > tool_calls then
      invalid "make" "tool_failures must not exceed tool_calls";
    check_tool_calls_by_name "make" tool_calls_by_name;
    {
      usage;
      responses;
      turns;
      tool_calls;
      tool_failures;
      tool_rejections;
      tool_calls_by_name;
      permission_denials;
    }

  let empty =
    {
      usage = Spice_llm.Usage.zero;
      responses = 0;
      turns = 0;
      tool_calls = 0;
      tool_failures = 0;
      tool_rejections = 0;
      tool_calls_by_name = [];
      permission_denials = 0;
    }

  type acc = {
    acc_usage : Spice_llm.Usage.t;
    acc_responses : int;
    acc_turns : int;
    acc_tool_calls : int;
    acc_tool_failures : int;
    acc_tool_rejections : int;
    acc_tool_calls_by_name : int Tool_name_map.t;
    acc_permission_denials : int;
  }

  let empty_acc : acc =
    {
      acc_usage = Spice_llm.Usage.zero;
      acc_responses = 0;
      acc_turns = 0;
      acc_tool_calls = 0;
      acc_tool_failures = 0;
      acc_tool_rejections = 0;
      acc_tool_calls_by_name = Tool_name_map.empty;
      acc_permission_denials = 0;
    }

  let add_tool_call name counts =
    Tool_name_map.update name
      (function
        | None -> Some 1 | Some count -> Some (incr_checked "metrics" count))
      counts

  let add_response response (acc : acc) =
    {
      acc with
      acc_usage =
        Spice_llm.Usage.add acc.acc_usage
          (Option.value
             (Spice_llm.Response.usage response)
             ~default:Spice_llm.Usage.zero);
      acc_responses = incr_checked "metrics" acc.acc_responses;
    }

  let add_tool_finished execution (acc : acc) =
    let result = Tool_claim.Finished.result execution in
    {
      acc with
      acc_tool_calls = incr_checked "metrics" acc.acc_tool_calls;
      acc_tool_failures =
        (if Spice_llm.Tool.Result.is_error result then
           incr_checked "metrics" acc.acc_tool_failures
         else acc.acc_tool_failures);
      acc_tool_calls_by_name =
        add_tool_call
          (Spice_llm.Tool.Result.name result)
          acc.acc_tool_calls_by_name;
    }

  let add_event acc = function
    | Event.Response_appended response -> add_response response acc
    | Event.Turn_finished _ ->
        { acc with acc_turns = incr_checked "metrics" acc.acc_turns }
    | Event.Tool_claim_finished execution -> add_tool_finished execution acc
    | Event.Message_appended (Spice_llm.Message.Tool_result result)
      when Spice_llm.Tool.Result.is_error result ->
        {
          acc with
          acc_tool_rejections = incr_checked "metrics" acc.acc_tool_rejections;
        }
    | Event.Permission_resolved reply -> (
        match Permission.Resolved.decision reply with
        | Permission.Resolved.Denied _ ->
            {
              acc with
              acc_permission_denials =
                incr_checked "metrics" acc.acc_permission_denials;
            }
        | Permission.Resolved.Allowed _ -> acc)
    | Event.Turn_started _ | Event.Message_appended _
    | Event.Assistant_interrupted _
    | Event.Compaction_installed _ | Event.Permission_requested _
    | Event.Tool_claim_started _ ->
        acc

  let of_validated_events events =
    match events with
    | [] -> empty
    | _ :: _ ->
        let acc = List.fold_left add_event empty_acc events in
        let {
          acc_usage = usage;
          acc_responses = responses;
          acc_turns = turns;
          acc_tool_calls = tool_calls;
          acc_tool_failures = tool_failures;
          acc_tool_rejections = tool_rejections;
          acc_tool_calls_by_name = tool_calls_by_name;
          acc_permission_denials = permission_denials;
        } =
          acc
        in
        make ~usage ~responses ~turns ~tool_calls ~tool_failures ~tool_rejections
          ~tool_calls_by_name:(Tool_name_map.bindings tool_calls_by_name)
          ~permission_denials

  let equal a b = a = b

  let pp_by_name ppf entries =
    Format.pp_print_list
      ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
      (fun ppf (name, count) -> Format.fprintf ppf "%s=%d" name count)
      ppf entries

  let pp ppf
      ({
         usage;
         responses;
         turns;
         tool_calls;
         tool_failures;
         tool_rejections;
         tool_calls_by_name;
         permission_denials;
       } :
        t) =
    Format.fprintf ppf
      "@[<hov>{ usage = %a; responses = %d; turns = %d; tool_calls = %d; \
       tool_failures = %d; tool_rejections = %d; tool_calls_by_name = [%a]; \
       permission_denials = %d }@]"
      Spice_llm.Usage.pp usage responses turns tool_calls tool_failures
      tool_rejections pp_by_name tool_calls_by_name permission_denials

  let tool_call_count_jsont : (string * int) Jsont.t =
    Jsont.Object.map ~kind:"tool-call count" (fun name count -> (name, count))
    |> Jsont.Object.mem "name" Jsont.string ~enc:fst
    |> Jsont.Object.mem "count" Jsont.int ~enc:snd
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont =
    let make usage responses turns tool_calls tool_failures tool_rejections
        (tool_calls_by_name : (string * int) list) permission_denials =
      decode_invalid_arg (fun () ->
          make ~usage ~responses ~turns ~tool_calls ~tool_failures
            ~tool_rejections ~tool_calls_by_name ~permission_denials)
    in
    Jsont.Object.map ~kind:"session metrics" make
    |> Jsont.Object.mem "usage" Spice_llm.Usage.jsont ~enc:(fun (t : t) ->
        t.usage)
    |> Jsont.Object.mem "responses" Jsont.int ~enc:(fun (t : t) -> t.responses)
    |> Jsont.Object.mem "turns" Jsont.int ~enc:(fun (t : t) -> t.turns)
    |> Jsont.Object.mem "tool_calls" Jsont.int ~enc:(fun (t : t) -> t.tool_calls)
    |> Jsont.Object.mem "tool_failures" Jsont.int ~enc:(fun (t : t) ->
        t.tool_failures)
    |> Jsont.Object.mem "tool_rejections" Jsont.int ~enc:(fun (t : t) ->
        t.tool_rejections)
    |> Jsont.Object.mem "tool_calls_by_name" (Jsont.list tool_call_count_jsont)
         ~enc:(fun (t : t) -> t.tool_calls_by_name)
    |> Jsont.Object.mem "permission_denials" Jsont.int ~enc:(fun (t : t) ->
        t.permission_denials)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let metrics session = Metrics.of_validated_events (events session)

module Log = struct
  let append = append
  let append_all = append_all
end
