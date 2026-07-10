(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_session.Turn" fn message

let reject_empty_option fn field = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid fn (field ^ " must not be empty")

module Id =
  String_id.Make
    (struct
      let module_path = "Spice_session.Turn.Id"
      let kind = "turn id"
    end)
    ()

module Input = struct
  type t = User of Spice_llm.Content.t list | Continue

  let user content =
    if List.is_empty content then
      invalid "Input.user" "content must not be empty";
    User content

  let user_text text = user [ Spice_llm.Content.text text ]

  let text = function
    | Continue -> None
    | User content ->
        let texts =
          List.filter_map
            (function
              | Spice_llm.Content.Text text -> Some text
              | Spice_llm.Content.Media _ -> None)
            content
        in
        if List.is_empty texts then None else Some (String.concat " " texts)

  let continue = Continue
  let equal a b = a = b

  let pp ppf = function
    | User content ->
        Format.fprintf ppf "user[%d content block(s)]" (List.length content)
    | Continue -> Format.pp_print_string ppf "continue"

  let jsont =
    let user_case =
      Jsont.Object.map ~kind:"user turn input" (fun content ->
          decode_invalid_arg (fun () -> user content))
      |> Jsont.Object.mem "content" (Jsont.list Spice_llm.Content.jsont)
           ~enc:(function
           | User content -> content
           | Continue -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "user" ~dec:Fun.id
    in
    let continue_case =
      Jsont.Object.map ~kind:"continue turn input" Continue
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "continue" ~dec:Fun.id
    in
    let cases = List.map Jsont.Object.Case.make [ user_case; continue_case ] in
    let enc_case = function
      | User _ as input -> Jsont.Object.Case.value user_case input
      | Continue as input -> Jsont.Object.Case.value continue_case input
    in
    Jsont.Object.map ~kind:"turn input" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Outcome = struct
  type t =
    | Completed
    | Step_limit
    | Interrupted of { reason : string option; cancelled : bool }
    | Failed of { message : string }

  let completed = Completed
  let step_limit = Step_limit

  let interrupted ?reason ~cancelled () =
    reject_empty_option "Outcome.interrupted" "reason" reason;
    Interrupted { reason; cancelled }

  let failed ~message =
    if String.is_empty message then
      invalid "Outcome.failed" "message must not be empty";
    Failed { message }

  let equal a b = a = b

  let pp ppf = function
    | Completed -> Format.pp_print_string ppf "completed"
    | Step_limit -> Format.pp_print_string ppf "step-limit"
    | Interrupted { reason = None; cancelled } ->
        Format.fprintf ppf "interrupted(cancelled=%B)" cancelled
    | Interrupted { reason = Some reason; cancelled } ->
        Format.fprintf ppf "interrupted(reason=%S, cancelled=%B)" reason
          cancelled
    | Failed { message } -> Format.fprintf ppf "failed(%S)" message

  let jsont =
    let completed_case =
      Jsont.Object.map ~kind:"completed turn outcome" Completed
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "completed" ~dec:Fun.id
    in
    let step_limit_case =
      Jsont.Object.map ~kind:"step-limit turn outcome" Step_limit
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "step_limit" ~dec:Fun.id
    in
    let interrupted_case =
      Jsont.Object.map ~kind:"interrupted turn outcome" (fun reason cancelled ->
          decode_invalid_arg (fun () -> interrupted ?reason ~cancelled ()))
      |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(function
        | Interrupted { reason; _ } -> reason
        | Completed | Step_limit | Failed _ -> assert false)
      |> Jsont.Object.mem "cancelled" Jsont.bool ~enc:(function
        | Interrupted { cancelled; _ } -> cancelled
        | Completed | Step_limit | Failed _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "interrupted" ~dec:Fun.id
    in
    let failed_case =
      Jsont.Object.map ~kind:"failed turn outcome" (fun message ->
          decode_invalid_arg (fun () -> failed ~message))
      |> Jsont.Object.mem "message" Jsont.string ~enc:(function
        | Failed { message } -> message
        | Completed | Step_limit | Interrupted _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "failed" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ completed_case; step_limit_case; interrupted_case; failed_case ]
    in
    let enc_case = function
      | Completed as outcome -> Jsont.Object.Case.value completed_case outcome
      | Step_limit as outcome -> Jsont.Object.Case.value step_limit_case outcome
      | Interrupted _ as outcome ->
          Jsont.Object.Case.value interrupted_case outcome
      | Failed _ as outcome -> Jsont.Object.Case.value failed_case outcome
    in
    Jsont.Object.map ~kind:"turn outcome" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  id : Id.t;
  input : Input.t;
  model : Spice_llm.Model.t;
  options : Spice_llm.Request.Options.t;
  mode : string option;
  origin : string option;
  max_steps : int option;
  declarations : Spice_llm.Tool.t list;
  host_tools : string list;
}

let check_mode = function
  | None -> ()
  | Some mode ->
      if String.is_empty mode then invalid "make" "mode must not be empty"

let check_origin = function
  | None -> ()
  | Some origin ->
      if String.is_empty origin then invalid "make" "origin must not be empty"

let check_max_steps = function
  | None -> ()
  | Some max_steps ->
      if max_steps <= 0 then invalid "make" "max_steps must be positive"

let check_tool_contract declarations host_tools =
  let declaration_names = List.map Spice_llm.Tool.name declarations in
  let rec check_unique field seen = function
    | [] -> ()
    | name :: names ->
        if List.exists (String.equal name) seen then
          invalid "make" ("duplicate " ^ field ^ " name: " ^ name)
        else check_unique field (name :: seen) names
  in
  check_unique "declaration" [] declaration_names;
  check_unique "host tool" [] host_tools;
  List.iter
    (fun name ->
      if not (List.exists (String.equal name) declaration_names) then
        invalid "make" ("host tool has no declaration: " ^ name))
    host_tools

let make ~id ~input ~model ?(options = Spice_llm.Request.Options.default) ?mode
    ?origin ?max_steps ~declarations ~host_tools () =
  check_mode mode;
  check_origin origin;
  check_max_steps max_steps;
  check_tool_contract declarations host_tools;
  {
    id;
    input;
    model;
    options;
    mode;
    origin;
    max_steps;
    declarations;
    host_tools;
  }

let id t = t.id
let input t = t.input
let model t = t.model
let options t = t.options
let mode t = t.mode
let origin t = t.origin
let max_steps t = t.max_steps
let declarations t = t.declarations
let host_tools t = t.host_tools
let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf "@[<hov>{ id = %a; input = %a; model = %a }@]" Id.pp t.id
    Input.pp t.input Spice_llm.Model.pp t.model

let jsont =
  let make id input model options mode origin max_steps declarations host_tools =
    decode_invalid_arg (fun () ->
        make ~id ~input ~model ~options ?mode ?origin ?max_steps ~declarations
          ~host_tools ())
  in
  Jsont.Object.map ~kind:"session turn" make
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "input" Input.jsont ~enc:input
  |> Jsont.Object.mem "model" Spice_llm.Model.jsont ~enc:model
  |> Jsont.Object.mem "options" Spice_llm.Request.Options.jsont ~enc:options
  |> Jsont.Object.opt_mem "mode" Jsont.string ~enc:mode
  |> Jsont.Object.opt_mem "origin" Jsont.string ~enc:origin
  |> Jsont.Object.opt_mem "max_steps" Jsont.int ~enc:max_steps
  |> Jsont.Object.mem "declarations" (Jsont.list Spice_llm.Tool.jsont)
       ~enc:declarations
  |> Jsont.Object.mem "host_tools" (Jsont.list Jsont.string) ~enc:host_tools
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
