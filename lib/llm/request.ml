(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module String_set = Set.Make (String)

let invalid fn message = invalid_arg' "Spice_llm.Request" fn message

let is_json_object = function
  | Jsont.Object _ -> true
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      false

let is_tool_name_first c = Char.Ascii.is_letter c || Char.equal c '_'

let is_tool_name_rest c =
  is_tool_name_first c || Char.Ascii.is_digit c || Char.equal c '-'

let check_tool_name fn name =
  let len = String.length name in
  if len = 0 then invalid fn "tool name must not be empty";
  if len > 64 then invalid fn "tool name must be at most 64 characters";
  if not (is_tool_name_first name.[0]) then
    invalid fn "tool name must start with an ASCII letter or '_'";
  for index = 1 to len - 1 do
    if not (is_tool_name_rest name.[index]) then
      invalid fn
        "tool name must contain only ASCII letters, digits, '_', or '-'"
  done

module Options = struct
  type tool_choice = Auto | No_tools | Required | Tool of string

  module Reasoning_effort = struct
    type t = Disabled | Minimal | Low | Medium | High | Extra_high | Max

    let spellings =
      [
        ("none", Disabled);
        ("minimal", Minimal);
        ("low", Low);
        ("medium", Medium);
        ("high", High);
        ("xhigh", Extra_high);
        ("max", Max);
      ]

    let all = List.map snd spellings

    let to_string = function
      | Disabled -> "none"
      | Minimal -> "minimal"
      | Low -> "low"
      | Medium -> "medium"
      | High -> "high"
      | Extra_high -> "xhigh"
      | Max -> "max"

    let of_string s = List.assoc_opt s spellings
    let jsont = Jsont.enum ~kind:"reasoning effort" spellings
    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  type response_format =
    | Text
    | Json_schema of { name : string; schema : Jsont.json; strict : bool }

  type t = {
    tool_choice : tool_choice;
    max_output_tokens : int option;
    temperature : float option;
    reasoning_effort : Reasoning_effort.t option;
    response_format : response_format;
  }

  let check_tool_choice = function
    | Tool name -> check_tool_name "Options.make" name
    | Auto | No_tools | Required -> ()

  let check_max_output_tokens = function
    | None -> ()
    | Some value ->
        if value <= 0 then
          invalid "Options.make" "max_output_tokens must be positive"

  let check_temperature = function
    | None -> ()
    | Some value ->
        if (not (Float.is_finite value)) || value < 0. then
          invalid "Options.make" "temperature must be finite and non-negative"

  let check_response_format = function
    | Text -> ()
    | Json_schema { name; schema; strict = _ } ->
        if String.is_empty name then
          invalid "Options.make" "response format schema name must not be empty";
        if not (is_json_object schema) then
          invalid "Options.make" "response format schema must be a JSON object"

  let make ?(tool_choice = Auto) ?max_output_tokens ?temperature
      ?reasoning_effort ?(response_format = Text) () =
    check_tool_choice tool_choice;
    check_max_output_tokens max_output_tokens;
    check_temperature temperature;
    check_response_format response_format;
    {
      tool_choice;
      max_output_tokens;
      temperature;
      reasoning_effort;
      response_format;
    }

  let default = make ()
  let tool_choice t = t.tool_choice
  let max_output_tokens t = t.max_output_tokens
  let temperature t = t.temperature
  let reasoning_effort t = t.reasoning_effort
  let response_format t = t.response_format

  let response_format_jsont =
    let text =
      Jsont.Object.map ~kind:"text output" Text
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "text" ~dec:Fun.id
    in
    let json_schema =
      Jsont.Object.map ~kind:"JSON schema output" (fun name schema strict ->
          Json_schema { name; schema; strict })
      |> Jsont.Object.mem "name" Jsont.string ~enc:(function
        | Json_schema { name; _ } -> name
        | Text -> assert false)
      |> Jsont.Object.mem "schema" Jsont.json ~enc:(function
        | Json_schema { schema; _ } -> schema
        | Text -> assert false)
      |> Jsont.Object.mem "strict" Jsont.bool ~enc:(function
        | Json_schema { strict; _ } -> strict
        | Text -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "json_schema" ~dec:Fun.id
    in
    let cases = List.map Jsont.Object.Case.make [ text; json_schema ] in
    let enc_case = function
      | Text as output -> Jsont.Object.Case.value text output
      | Json_schema _ as output -> Jsont.Object.Case.value json_schema output
    in
    Jsont.Object.map ~kind:"response format" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let tool_choice_jsont =
    let auto =
      Jsont.Object.map ~kind:"automatic tool choice" Auto
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "auto" ~dec:Fun.id
    in
    let no_tools =
      Jsont.Object.map ~kind:"no-tools choice" No_tools
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "no_tools" ~dec:Fun.id
    in
    let required =
      Jsont.Object.map ~kind:"required tool choice" Required
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "required" ~dec:Fun.id
    in
    let tool =
      Jsont.Object.map ~kind:"named tool choice" (fun name -> Tool name)
      |> Jsont.Object.mem "name" Jsont.string ~enc:(function
        | Tool name -> name
        | Auto | No_tools | Required -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "tool" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make [ auto; no_tools; required; tool ]
    in
    let enc_case = function
      | Auto as choice -> Jsont.Object.Case.value auto choice
      | No_tools as choice -> Jsont.Object.Case.value no_tools choice
      | Required as choice -> Jsont.Object.Case.value required choice
      | Tool _ as choice -> Jsont.Object.Case.value tool choice
    in
    Jsont.Object.map ~kind:"tool choice" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont =
    let make tool_choice max_output_tokens temperature reasoning_effort
        response_format =
      decode_invalid_arg (fun () ->
          make ~tool_choice ?max_output_tokens ?temperature ?reasoning_effort
            ~response_format ())
    in
    Jsont.Object.map ~kind:"request options" make
    |> Jsont.Object.mem "tool_choice" tool_choice_jsont ~enc:tool_choice
    |> Jsont.Object.opt_mem "max_output_tokens" Jsont.int ~enc:max_output_tokens
    |> Jsont.Object.opt_mem "temperature" Jsont.number ~enc:temperature
    |> Jsont.Object.opt_mem "reasoning_effort" Reasoning_effort.jsont
         ~enc:reasoning_effort
    |> Jsont.Object.mem "response_format" response_format_jsont
         ~enc:response_format
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Error = struct
  type t =
    | Empty_transcript
    | Invalid_prelude_message of Message.t
    | Pending_tool_results of Tool.Call.t list
    | Duplicate_tool of string
    | Tool_choice_without_tools
    | Unknown_tool_choice of string

  let message = function
    | Empty_transcript -> "request transcript must not be empty"
    | Invalid_prelude_message message ->
        "request prelude accepts only system, developer, and user messages, \
         got "
        ^ begin match message with
        | Message.System _ -> "system"
        | Message.Developer _ -> "developer"
        | Message.User _ -> "user"
        | Message.Assistant _ -> "assistant"
        | Message.Tool_result _ -> "tool_result"
        end
    | Pending_tool_results calls ->
        let ids = List.map Tool.Call.id calls |> String.concat ", " in
        "request transcript is awaiting tool results: " ^ ids
    | Duplicate_tool name -> "duplicate tool declaration: " ^ name
    | Tool_choice_without_tools ->
        "tool choice requires a tool but none are declared"
    | Unknown_tool_choice name -> "tool choice names undeclared tool: " ^ name

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Prelude = struct
  type t = Message.t list

  let empty = []

  let rec make = function
    | [] -> Ok empty
    | (Message.System _ | Message.Developer _ | Message.User _) :: _ as messages
      ->
        check [] messages
    | message :: _ -> Error (Error.Invalid_prelude_message message)

  and check rev = function
    | [] -> Ok (List.rev rev)
    | ((Message.System _ | Message.Developer _ | Message.User _) as message)
      :: messages ->
        check (message :: rev) messages
    | message :: _ -> Error (Error.Invalid_prelude_message message)

  let append t messages =
    match make messages with
    | Ok appended -> Ok (t @ appended)
    | Error _ as error -> error

  let messages t = t
end

let check_unique_tools tools =
  let rec loop seen = function
    | [] -> Ok ()
    | tool :: rest ->
        let name = Tool.name tool in
        if String_set.mem name seen then Error (Error.Duplicate_tool name)
        else loop (String_set.add name seen) rest
  in
  loop String_set.empty tools

let check_tool_choice tools options =
  match Options.tool_choice options with
  | Options.Auto | Options.No_tools -> Ok ()
  | Options.Required -> (
      match tools with
      | [] -> Error Error.Tool_choice_without_tools
      | _ -> Ok ())
  | Options.Tool name ->
      if List.exists (fun tool -> String.equal name (Tool.name tool)) tools then
        Ok ()
      else Error (Error.Unknown_tool_choice name)

type t = {
  model : Model.t;
  prelude : Prelude.t;
  tools : Tool.t list;
  options : Options.t;
  cache_key : string option;
  transcript : Transcript.t;
}

let make ~model ?(prelude = Prelude.empty) ?(tools = [])
    ?(options = Options.default) ?cache_key transcript =
  (match cache_key with
  | Some "" -> invalid "make" "cache_key must not be empty"
  | Some _ | None -> ());
  if Transcript.is_empty transcript then Error Error.Empty_transcript
  else
    match Transcript.require_ready transcript with
    | Error (Transcript.Error.Pending_tool_results calls) ->
        Error (Error.Pending_tool_results calls)
    | Error transcript_error ->
        invalid "make" (Transcript.Error.message transcript_error)
    | Ok () -> (
        match check_unique_tools tools with
        | Error _ as error -> error
        | Ok () -> (
            match check_tool_choice tools options with
            | Error _ as error -> error
            | Ok () ->
                Ok { model; prelude; tools; options; cache_key; transcript }))

let make_exn ~model ?prelude ?tools ?options ?cache_key transcript =
  match make ~model ?prelude ?tools ?options ?cache_key transcript with
  | Ok request -> request
  | Error error -> invalid "make_exn" (Error.message error)

let append_prelude t messages =
  match Prelude.append t.prelude messages with
  | Error _ as error -> error
  | Ok prelude ->
      make ~model:t.model ~prelude ~tools:t.tools ~options:t.options
        ?cache_key:t.cache_key t.transcript

let model t = t.model
let tools t = t.tools
let options t = t.options
let prelude t = t.prelude
let transcript t = t.transcript
let messages t = Prelude.messages t.prelude @ Transcript.messages t.transcript
let cache_key t = t.cache_key
