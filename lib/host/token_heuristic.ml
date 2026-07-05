(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let string text = max 1 ((String.length text + 3) / 4)

let content = function
  | Spice_llm.Content.Text text -> string text
  | Spice_llm.Content.Media { media_type; source = `Uri uri } ->
      string media_type + string uri + 256
  | Spice_llm.Content.Media { media_type; source = `Base64 data } ->
      string media_type + string data

let contents contents =
  List.fold_left (fun total c -> total + content c) 0 contents

let message = function
  | Spice_llm.Message.System text | Spice_llm.Message.Developer text ->
      string text
  | Spice_llm.Message.User cs -> contents cs
  | Spice_llm.Message.Assistant assistant ->
      let text_tokens =
        List.fold_left
          (fun total text -> total + string text)
          0
          (Spice_llm.Message.Assistant.texts assistant)
      in
      let call_tokens =
        List.length (Spice_llm.Message.Assistant.tool_calls assistant) * 64
      in
      let reasoning_tokens =
        List.length (Spice_llm.Message.Assistant.reasonings assistant) * 64
      in
      text_tokens + call_tokens + reasoning_tokens
  | Spice_llm.Message.Tool_result result -> (
      match Spice_llm.Tool.Result.texts result with
      | [] -> 1
      | texts -> List.fold_left (fun total text -> total + string text) 0 texts)

let messages msgs = List.fold_left (fun total m -> total + message m) 0 msgs

let json json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> string text
  | Error _ -> 1

let tool tool =
  let description =
    Option.value (Spice_llm.Tool.description tool) ~default:""
  in
  string (Spice_llm.Tool.name tool)
  + string description
  + json (Spice_llm.Tool.input_schema tool)
  + 64

let request request =
  messages (Spice_llm.Request.messages request)
  + List.fold_left
      (fun total t -> total + tool t)
      0
      (Spice_llm.Request.tools request)
