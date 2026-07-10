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
    | Archived
    | Deleted
    | Active_turn of Turn.Id.t
    | Unknown_turn of Turn.Id.t
    | Turn_not_finished of Turn.Id.t

  let message = function
    | State error -> State.Error.message error
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
  | Error error -> Error (Error.State error)
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
          | Error error -> Error (Error.State error)
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
  (* CR: if you need to expose Metrics, just do Metrics = Metrics, otherwise remove this entirely. *)
  include Metrics

  let of_session session = of_events (events session)
end

module Log = struct
  let append = append
  let append_all = append_all
end
