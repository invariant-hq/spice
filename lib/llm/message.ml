(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_llm.Message" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

module Assistant = struct
  module Reasoning = struct
    type t = {
      id : string option;
      summary : string option;
      text : string option;
      encrypted : string option;
      signature : string option;
      metadata : Jsont.json option;
    }

    let check_opt fn field = Option.iter (reject_empty fn field)

    let make ?id ?summary ?text ?encrypted ?signature ?metadata () =
      check_opt "Assistant.Reasoning.make" "id" id;
      check_opt "Assistant.Reasoning.make" "summary" summary;
      check_opt "Assistant.Reasoning.make" "text" text;
      check_opt "Assistant.Reasoning.make" "encrypted" encrypted;
      check_opt "Assistant.Reasoning.make" "signature" signature;
      begin match (id, summary, text, encrypted, signature, metadata) with
      | None, None, None, None, None, None ->
          invalid "Assistant.Reasoning.make" "at least one field is required"
      | _ -> ()
      end;
      { id; summary; text; encrypted; signature; metadata }

    let id t = t.id
    let summary t = t.summary
    let text t = t.text
    let encrypted t = t.encrypted
    let signature t = t.signature
    let metadata t = t.metadata

    let jsont =
      let make id summary text encrypted signature metadata =
        decode_invalid_arg (fun () ->
            make ?id ?summary ?text ?encrypted ?signature ?metadata ())
      in
      Jsont.Object.map ~kind:"assistant reasoning part" make
      |> Jsont.Object.opt_mem "id" Jsont.string ~enc:id
      |> Jsont.Object.opt_mem "summary" Jsont.string ~enc:summary
      |> Jsont.Object.opt_mem "text" Jsont.string ~enc:text
      |> Jsont.Object.opt_mem "encrypted" Jsont.string ~enc:encrypted
      |> Jsont.Object.opt_mem "signature" Jsont.string ~enc:signature
      |> Jsont.Object.opt_mem "metadata" Jsont.json ~enc:metadata
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  type part =
    | Text of string
    | Tool_call of Tool.Call.t
    | Reasoning of Reasoning.t

  let text_part value =
    reject_empty "Assistant.text_part" "text" value;
    Text value

  let tool_call call = Tool_call call
  let reasoning_part reasoning = Reasoning reasoning

  type t = { parts : part list }

  let check_part = function
    | Text "" -> invalid "Assistant.make" "text part must not be empty"
    | Text _ | Tool_call _ | Reasoning _ -> ()

  let empty = { parts = [] }

  let make parts =
    begin match parts with
    | [] -> invalid "Assistant.make" "parts must not be empty"
    | _ -> ()
    end;
    List.iter check_part parts;
    { parts }

  let text value = make [ text_part value ]
  let parts t = t.parts

  let tool_calls t =
    List.filter_map
      (function Tool_call call -> Some call | Text _ | Reasoning _ -> None)
      t.parts

  let texts t =
    List.filter_map
      (function Text text -> Some text | Tool_call _ | Reasoning _ -> None)
      t.parts

  let reasonings t =
    List.filter_map
      (function
        | Reasoning reasoning -> Some reasoning | Text _ | Tool_call _ -> None)
      t.parts

  let part_jsont =
    let text =
      Jsont.Object.map ~kind:"assistant text part" (fun text ->
          decode_invalid_arg (fun () -> text_part text))
      |> Jsont.Object.mem "text" Jsont.string ~enc:(function
        | Text text -> text
        | Tool_call _ | Reasoning _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "text" ~dec:Fun.id
    in
    let tool_call =
      Jsont.Object.map ~kind:"assistant tool-call part" tool_call
      |> Jsont.Object.mem "tool_call" Tool.Call.jsont ~enc:(function
        | Tool_call call -> call
        | Text _ | Reasoning _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "tool_call" ~dec:Fun.id
    in
    let reasoning =
      Jsont.Object.map ~kind:"assistant reasoning part" reasoning_part
      |> Jsont.Object.mem "reasoning" Reasoning.jsont ~enc:(function
        | Reasoning reasoning -> reasoning
        | Text _ | Tool_call _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "reasoning" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make [ text; tool_call; reasoning ]
    in
    let enc_case = function
      | Text _ as part -> Jsont.Object.Case.value text part
      | Tool_call _ as part -> Jsont.Object.Case.value tool_call part
      | Reasoning _ as part -> Jsont.Object.Case.value reasoning part
    in
    Jsont.Object.map ~kind:"assistant part" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont =
    let of_parts = function [] -> empty | parts -> make parts in
    let make parts = decode_invalid_arg (fun () -> of_parts parts) in
    Jsont.Object.map ~kind:"assistant message" make
    |> Jsont.Object.mem "parts" (Jsont.list part_jsont) ~enc:parts
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t =
  | System of string
  | Developer of string
  | User of Content.t list
  | Assistant of Assistant.t
  | Tool_result of Tool.Result.t

let system value =
  reject_empty "system" "text" value;
  System value

let developer value =
  reject_empty "developer" "text" value;
  Developer value

let user content =
  match content with
  | [] -> invalid "user" "content must not be empty"
  | _ -> User content

let user_text value = user [ Content.text value ]
let assistant value = Assistant value
let assistant_text value = assistant (Assistant.text value)
let tool_result value = Tool_result value
let equal a b = a = b

let jsont =
  let system =
    Jsont.Object.map ~kind:"system message" (fun text ->
        decode_invalid_arg (fun () -> system text))
    |> Jsont.Object.mem "text" Jsont.string ~enc:(function
      | System text -> text
      | Developer _ | User _ | Assistant _ | Tool_result _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "system" ~dec:Fun.id
  in
  let developer =
    Jsont.Object.map ~kind:"developer message" (fun text ->
        decode_invalid_arg (fun () -> developer text))
    |> Jsont.Object.mem "text" Jsont.string ~enc:(function
      | Developer text -> text
      | System _ | User _ | Assistant _ | Tool_result _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "developer" ~dec:Fun.id
  in
  let user =
    Jsont.Object.map ~kind:"user message" (fun content ->
        decode_invalid_arg (fun () -> user content))
    |> Jsont.Object.mem "content" (Jsont.list Content.jsont) ~enc:(function
      | User content -> content
      | System _ | Developer _ | Assistant _ | Tool_result _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "user" ~dec:Fun.id
  in
  let assistant =
    Jsont.Object.map ~kind:"assistant message" assistant
    |> Jsont.Object.mem "assistant" Assistant.jsont ~enc:(function
      | Assistant assistant -> assistant
      | System _ | Developer _ | User _ | Tool_result _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "assistant" ~dec:Fun.id
  in
  let tool_result =
    Jsont.Object.map ~kind:"tool-result message" tool_result
    |> Jsont.Object.mem "tool_result" Tool.Result.jsont ~enc:(function
      | Tool_result result -> result
      | System _ | Developer _ | User _ | Assistant _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "tool_result" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [ system; developer; user; assistant; tool_result ]
  in
  let enc_case = function
    | System _ as message -> Jsont.Object.Case.value system message
    | Developer _ as message -> Jsont.Object.Case.value developer message
    | User _ as message -> Jsont.Object.Case.value user message
    | Assistant _ as message -> Jsont.Object.Case.value assistant message
    | Tool_result _ as message -> Jsont.Object.Case.value tool_result message
  in
  Jsont.Object.map ~kind:"message" Fun.id
  |> Jsont.Object.case_mem "role" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
