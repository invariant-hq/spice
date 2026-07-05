(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

module Stop = struct
  let invalid fn message = invalid_arg' "Spice_llm.Response.Stop" fn message

  let is_label_char c =
    Char.Ascii.is_lower c || Char.Ascii.is_digit c || Char.equal c '_'

  let valid_label label =
    let len = String.length label in
    len > 0
    && Char.Ascii.is_lower label.[0]
    &&
    let rec loop index =
      index >= len || (is_label_char label.[index] && loop (index + 1))
    in
    loop 1

  type t = string

  type view =
    | End_turn
    | Tool_call
    | Length
    | Content_filter
    | Refusal
    | Other of string

  let end_turn = "end_turn"
  let tool_call = "tool_call"
  let length = "length"
  let content_filter = "content_filter"
  let refusal = "refusal"
  let reserved = [ end_turn; tool_call; length; content_filter; refusal ]
  let is_reserved label = List.exists (String.equal label) reserved

  let check_label fn label =
    if not (valid_label label) then
      invalid fn
        "label must start with a lowercase ASCII letter and contain only \
         lowercase ASCII letters, digits, or '_'";
    if is_reserved label then invalid fn "label is reserved"

  let other label =
    check_label "other" label;
    label

  let label t = t

  let of_label label =
    if not (valid_label label) then None
    else if String.equal label end_turn then Some end_turn
    else if String.equal label tool_call then Some tool_call
    else if String.equal label length then Some length
    else if String.equal label content_filter then Some content_filter
    else if String.equal label refusal then Some refusal
    else Some label

  let view t =
    if String.equal t end_turn then End_turn
    else if String.equal t tool_call then Tool_call
    else if String.equal t length then Length
    else if String.equal t content_filter then Content_filter
    else if String.equal t refusal then Refusal
    else Other t

  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t
  let decode_error message = Jsont.Error.msg Jsont.Meta.none message

  let jsont =
    Jsont.map ~kind:"LLM stop reason"
      ~dec:(fun label ->
        match of_label label with
        | Some stop -> stop
        | None -> decode_error "invalid stop reason label")
      ~enc:label Jsont.string
end

let invalid fn message = invalid_arg' "Spice_llm.Response" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let reject_empty_option fn field = function
  | None -> ()
  | Some value -> reject_empty fn field value

type t = {
  model : Model.t;
  response_model : string option;
  response_id : string option;
  provider_stop : string option;
  stop : Stop.t option;
  usage : Usage.t option;
  reasoning_summary : string list;
  assistant : Message.Assistant.t;
}

let make ~model ?response_model ?response_id ?provider_stop ?stop ?usage
    ?(reasoning_summary = []) assistant =
  reject_empty_option "make" "response_model" response_model;
  reject_empty_option "make" "response_id" response_id;
  reject_empty_option "make" "provider_stop" provider_stop;
  List.iter (reject_empty "make" "reasoning_summary") reasoning_summary;
  {
    model;
    response_model;
    response_id;
    provider_stop;
    stop;
    usage;
    reasoning_summary;
    assistant;
  }

let assistant t = t.assistant
let message t = Message.assistant t.assistant
let texts t = Message.Assistant.texts t.assistant
let text ?(sep = "") t = String.concat sep (texts t)
let tool_calls t = Message.Assistant.tool_calls t.assistant
let has_tool_calls t = match tool_calls t with [] -> false | _ -> true
let model t = t.model
let response_model t = t.response_model
let response_id t = t.response_id
let provider_stop t = t.provider_stop
let stop t = t.stop
let usage t = t.usage
let reasoning_summary t = t.reasoning_summary

let jsont =
  let make model response_model response_id provider_stop stop usage
      reasoning_summary assistant =
    decode_invalid_arg (fun () ->
        make ~model ?response_model ?response_id ?provider_stop ?stop ?usage
          ~reasoning_summary assistant)
  in
  Jsont.Object.map ~kind:"LLM response" make
  |> Jsont.Object.mem "model" Model.jsont ~enc:model
  |> Jsont.Object.opt_mem "response_model" Jsont.string ~enc:response_model
  |> Jsont.Object.opt_mem "response_id" Jsont.string ~enc:response_id
  |> Jsont.Object.opt_mem "provider_stop" Jsont.string ~enc:provider_stop
  |> Jsont.Object.opt_mem "stop" Stop.jsont ~enc:stop
  |> Jsont.Object.opt_mem "usage" Usage.jsont ~enc:usage
  |> Jsont.Object.mem "reasoning_summary" (Jsont.list Jsont.string)
       ~enc:reasoning_summary
  |> Jsont.Object.mem "assistant" Message.Assistant.jsont ~enc:assistant
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
