(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_session.Metadata" fn message

module Status = struct
  type t = Active | Archived | Deleted

  let is_active = function Active -> true | Archived | Deleted -> false
  let is_archived = function Archived -> true | Active | Deleted -> false
  let is_deleted = function Deleted -> true | Active | Archived -> false
  let equal a b = a = b

  let pp ppf = function
    | Active -> Format.pp_print_string ppf "active"
    | Archived -> Format.pp_print_string ppf "archived"
    | Deleted -> Format.pp_print_string ppf "deleted"

  let jsont =
    Jsont.enum ~kind:"session status"
      [ ("active", Active); ("archived", Archived); ("deleted", Deleted) ]
end

module Forked_from = struct
  type t = { parent : Id.t; copied_events : int }

  let make ~parent ~copied_events =
    if copied_events < 0 then
      invalid "Forked_from.make" "copied_events must not be negative";
    { parent; copied_events }

  let parent t = t.parent
  let copied_events t = t.copied_events

  let equal a b =
    Id.equal a.parent b.parent && Int.equal a.copied_events b.copied_events

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ parent = %a; copied_events = %d }@]" Id.pp
      t.parent t.copied_events

  let jsont =
    Jsont.Object.map ~kind:"session fork lineage" (fun parent copied_events ->
        decode_invalid_arg (fun () -> make ~parent ~copied_events))
    |> Jsont.Object.mem "parent" Id.jsont ~enc:parent
    |> Jsont.Object.mem "copied_events" Jsont.int ~enc:copied_events
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  title : string option;
  status : Status.t;
  forked_from : Forked_from.t option;
  cwd : Spice_path.Abs.t;
  created_at : Time.t;
  updated_at : Time.t;
}

let check_title fn = function
  | None -> ()
  | Some title ->
      if String.is_empty title then invalid fn "title must not be empty"

let check_times fn ~created_at ~updated_at =
  if Time.compare updated_at created_at < 0 then
    invalid fn "updated_at must not be before created_at"

let make ?title ?(status = Status.Active) ?forked_from ~cwd ~created_at
    ~updated_at () =
  check_title "make" title;
  check_times "make" ~created_at ~updated_at;
  { title; status; forked_from; cwd; created_at; updated_at }

let title t = t.title
let status t = t.status
let fork t = t.forked_from
let cwd t = t.cwd
let created_at t = t.created_at
let updated_at t = t.updated_at

let with_title title t =
  check_title "with_title" title;
  { t with title }

let with_status status t = { t with status }
let with_fork forked_from t = { t with forked_from }

let touch updated_at t =
  check_times "touch" ~created_at:t.created_at ~updated_at;
  { t with updated_at }

let is_active t = Status.is_active t.status
let is_archived t = Status.is_archived t.status
let is_deleted t = Status.is_deleted t.status
let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf
    "@[<hov>{ title = %a; status = %a; forked_from = %a; cwd = %a; created_at \
     = %a; updated_at = %a }@]"
    (Format.pp_print_option Format.pp_print_string)
    t.title Status.pp t.status
    (Format.pp_print_option Forked_from.pp)
    t.forked_from Spice_path.Abs.pp t.cwd Time.pp t.created_at Time.pp
    t.updated_at

let absolute_path_jsont =
  Jsont.map ~kind:"absolute path"
    ~dec:(fun raw ->
      match Spice_path.Abs.of_string raw with
      | Ok path -> path
      | Error error -> decode_error (Spice_path.Error.message error))
    ~enc:Spice_path.Abs.to_string Jsont.string

let jsont =
  Jsont.Object.map ~kind:"session metadata"
    (fun title status forked_from cwd created_at updated_at ->
      decode_invalid_arg (fun () ->
          make ?title ~status ?forked_from ~cwd ~created_at ~updated_at ()))
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:title
  |> Jsont.Object.mem "status" Status.jsont ~enc:status
  |> Jsont.Object.opt_mem "forked_from" Forked_from.jsont ~enc:fork
  |> Jsont.Object.mem "cwd" absolute_path_jsont ~enc:cwd
  |> Jsont.Object.mem "created_at" Time.jsont ~enc:created_at
  |> Jsont.Object.mem "updated_at" Time.jsont ~enc:updated_at
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
