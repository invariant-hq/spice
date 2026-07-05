(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module String_set = Set.Make (String)
module String_map = Map.Make (String)

let invalid fn message = invalid_arg' "Spice_llm.Transcript" fn message

type pending = {
  calls : Tool.Call.t list;
  expected_names : string String_map.t;
  answered : String_set.t;
}

type t = { rev_messages : Message.t list; pending : pending option }

module Error = struct
  type t =
    | Tool_result_without_call of Tool.Result.t
    | Unknown_tool_result of { call_id : string }
    | Duplicate_tool_result of { call_id : string }
    | Tool_result_name_mismatch of {
        call_id : string;
        expected : string;
        actual : string;
      }
    | Duplicate_tool_call of { call_id : string }
    | Pending_tool_results of Tool.Call.t list

  let message = function
    | Tool_result_without_call result ->
        "tool result without preceding assistant tool call: "
        ^ Tool.Result.call_id result
    | Unknown_tool_result { call_id } ->
        "tool result names unknown call_id: " ^ call_id
    | Duplicate_tool_result { call_id } -> "duplicate tool result: " ^ call_id
    | Tool_result_name_mismatch { call_id; expected; actual } ->
        "tool result name does not match call_id " ^ call_id ^ ": expected "
        ^ expected ^ ", got " ^ actual
    | Duplicate_tool_call { call_id } -> "duplicate tool call: " ^ call_id
    | Pending_tool_results calls ->
        let ids = List.map Tool.Call.id calls |> String.concat ", " in
        "assistant tool calls are missing tool results: " ^ ids

  let pp ppf error = Format.pp_print_string ppf (message error)
end

open Error

type state = Ready | Awaiting_tool_results of Tool.Call.t * Tool.Call.t list

let empty = { rev_messages = []; pending = None }
let is_empty t = match t.rev_messages with [] -> true | _ -> false
let messages t = List.rev t.rev_messages
let length t = List.length t.rev_messages

let unanswered pending =
  List.filter
    (fun call -> not (String_set.mem (Tool.Call.id call) pending.answered))
    pending.calls

let pending_calls = function None -> [] | Some pending -> unanswered pending
let pending t = pending_calls t.pending

let state t =
  match pending t with
  | [] -> Ready
  | call :: calls -> Awaiting_tool_results (call, calls)

let is_ready t =
  match state t with Ready -> true | Awaiting_tool_results _ -> false

let require_ready t =
  match state t with
  | Ready -> Ok ()
  | Awaiting_tool_results (call, calls) ->
      Error (Pending_tool_results (call :: calls))

let expected_map calls =
  List.fold_left
    (fun map call ->
      String_map.add (Tool.Call.id call) (Tool.Call.name call) map)
    String_map.empty calls

let call_ids_unique calls =
  let rec loop seen = function
    | [] -> Ok ()
    | call :: rest ->
        let call_id = Tool.Call.id call in
        if String_set.mem call_id seen then
          Error (Duplicate_tool_call { call_id })
        else loop (String_set.add call_id seen) rest
  in
  loop String_set.empty calls

let start_pending assistant =
  match Message.Assistant.tool_calls assistant with
  | [] -> Ok None
  | calls -> (
      match call_ids_unique calls with
      | Error _ as error -> error
      | Ok () ->
          Ok
            (Some
               {
                 calls;
                 expected_names = expected_map calls;
                 answered = String_set.empty;
               }))

let pending_is_complete pending =
  match unanswered pending with [] -> true | _ -> false

let close_pending = function
  | None -> Ok ()
  | Some pending -> (
      match unanswered pending with
      | [] -> Ok ()
      | missing -> Error (Pending_tool_results missing))

let answer_result result pending =
  let call_id = Tool.Result.call_id result in
  match String_map.find_opt call_id pending.expected_names with
  | None -> Error (Unknown_tool_result { call_id })
  | Some expected_name ->
      if String_set.mem call_id pending.answered then
        Error (Duplicate_tool_result { call_id })
      else
        let actual = Tool.Result.name result in
        if not (String.equal expected_name actual) then
          Error
            (Tool_result_name_mismatch
               { call_id; expected = expected_name; actual })
        else
          let pending =
            { pending with answered = String_set.add call_id pending.answered }
          in
          if pending_is_complete pending then Ok None else Ok (Some pending)

let push message pending t =
  Ok { rev_messages = message :: t.rev_messages; pending }

let add message t =
  match message with
  | Message.Tool_result result -> (
      match t.pending with
      | None -> Error (Tool_result_without_call result)
      | Some pending -> (
          match answer_result result pending with
          | Error _ as error -> error
          | Ok pending -> push message pending t))
  | Message.System _ | Message.Developer _ | Message.User _ -> (
      match close_pending t.pending with
      | Error _ as error -> error
      | Ok () -> push message None t)
  | Message.Assistant assistant -> (
      match close_pending t.pending with
      | Error _ as error -> error
      | Ok () -> (
          match start_pending assistant with
          | Error _ as error -> error
          | Ok pending -> push message pending t))

let of_list messages =
  let rec loop t = function
    | [] -> Ok t
    | message :: rest -> (
        match add message t with
        | Error _ as error -> error
        | Ok t -> loop t rest)
  in
  loop empty messages

let raise_error fn error = invalid fn (Error.message error)

let of_list_exn messages =
  match of_list messages with
  | Ok t -> t
  | Error error -> raise_error "of_list_exn" error

let add_exn message t =
  match add message t with
  | Ok t -> t
  | Error error -> raise_error "add_exn" error

let add_response response t = add (Response.message response) t

let last_assistant t =
  let rec loop = function
    | [] -> None
    | Message.Assistant assistant :: _ -> Some assistant
    | ( Message.System _ | Message.Developer _ | Message.User _
      | Message.Tool_result _ )
      :: rest ->
        loop rest
  in
  loop t.rev_messages

let jsont =
  let make messages =
    match of_list messages with
    | Ok transcript -> transcript
    | Error error -> decode_error (Error.message error)
  in
  Jsont.Object.map ~kind:"LLM transcript" make
  |> Jsont.Object.mem "messages" (Jsont.list Message.jsont) ~enc:messages
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
