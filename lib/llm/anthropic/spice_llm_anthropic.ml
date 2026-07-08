(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Spice_llm
module Config = Config

let log_src = Logs.Src.create "spice.llm.anthropic" ~doc:"Anthropic provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let provider = Llm.Provider.make "anthropic"
let api = Llm.Model.Api.make Api.api
let model id = Llm.Model.make ~provider ~api ~id

module Credential = struct
  type t = Api_key of string | Bearer of string

  let contains_newline value =
    String.exists (function '\n' | '\r' -> true | _ -> false) value

  let check_header_value fn value =
    if String.is_empty value then
      invalid_arg ("Spice_llm_anthropic.Credential." ^ fn ^ ": empty value");
    if contains_newline value then
      invalid_arg
        ("Spice_llm_anthropic.Credential." ^ fn ^ ": value contains newline")

  let api_key key =
    check_header_value "api_key" key;
    Api_key key

  let bearer token =
    check_header_value "bearer" token;
    Bearer token

  let api_auth = function
    | Api_key key -> Api.Client.Api_key key
    | Bearer token -> Api.Client.Bearer token
end

let llm_error ?(phase = Llm.Error.Startup) ?status ?request_id ?redacted_body
    kind message =
  Llm.Error.make ~kind ~phase ~provider ?status ?request_id ?redacted_body
    message

let invalid_request message =
  Error (llm_error Llm.Error.Invalid_request message)

let unsupported message = Error (llm_error Llm.Error.Unsupported message)

let decode_error message =
  Error (llm_error ~phase:Llm.Error.Stream Llm.Error.Decode message)

let stream_error kind message = llm_error ~phase:Llm.Error.Stream kind message

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "Anthropic request cancelled"

let transport_kind message =
  if String.includes ~affix:"timed out" (String.lowercase_ascii message) then
    Llm.Error.Timeout
  else Llm.Error.Transport

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid_arg ("JSON encode failed: " ^ message)

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> Ok json
  | Error message -> decode_error ("Anthropic JSON decode failed: " ^ message)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let int_field name json =
  match object_field name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (int_of_float value)
  | Some (Jsont.String (value, _)) -> int_of_string_opt value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let result_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Error error -> Error error
        | Ok value -> loop (value :: acc) rest)
  in
  loop [] values

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let int_member name value = json_member name (Jsont.Json.int value)
let list_member name value = json_member name (Jsont.Json.list value)

let add_opt member name value fields =
  match value with None -> fields | Some value -> member name value :: fields

let encode_image_source media_type = function
  | `Base64 data ->
      Ok
        (Jsont.Json.object'
           [
             string_member "type" "base64";
             string_member "media_type" media_type;
             string_member "data" data;
           ])
  | `Uri url ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "url"; string_member "url" url ])

let encode_user_content = function
  | Llm.Content.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "text"; string_member "text" text ])
  | Llm.Content.Media { media_type; source } ->
      if not (String.starts_with ~prefix:"image/" media_type) then
        unsupported "Anthropic Messages supports image media only"
      else
        Result.map
          (fun source ->
            Jsont.Json.object'
              [ string_member "type" "image"; json_member "source" source ])
          (encode_image_source media_type source)

let encode_assistant_part = function
  | Llm.Message.Assistant.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "text"; string_member "text" text ])
  | Llm.Message.Assistant.Tool_call call ->
      Ok
        (Jsont.Json.object'
           [
             string_member "type" "tool_use";
             string_member "id" (Llm.Tool.Call.id call);
             string_member "name" (Llm.Tool.Call.name call);
             json_member "input" (Llm.Tool.Call.input call);
           ])
  | Llm.Message.Assistant.Reasoning reasoning -> (
      match Llm.Message.Assistant.Reasoning.encrypted reasoning with
      | Some data ->
          Ok
            (Jsont.Json.object'
               [
                 string_member "type" "redacted_thinking";
                 string_member "data" data;
               ])
      | None -> (
          let thinking =
            match Llm.Message.Assistant.Reasoning.text reasoning with
            | Some text -> Some text
            | None -> Llm.Message.Assistant.Reasoning.summary reasoning
          in
          match thinking with
          | None ->
              unsupported
                "Anthropic Messages reasoning parts require text or encrypted \
                 data"
          | Some thinking ->
              let fields =
                [
                  string_member "type" "thinking";
                  string_member "thinking" thinking;
                ]
              in
              let fields =
                add_opt string_member "signature"
                  (Llm.Message.Assistant.Reasoning.signature reasoning)
                  fields
              in
              Ok (Jsont.Json.object' (List.rev fields))))

let encode_tool_result_content_item = function
  | Llm.Content.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "text"; string_member "text" text ])
  | Llm.Content.Media { media_type; source } ->
      if not (String.starts_with ~prefix:"image/" media_type) then
        unsupported "Anthropic Messages tool-result media supports images only"
      else
        Result.map
          (fun source ->
            Jsont.Json.object'
              [ string_member "type" "image"; json_member "source" source ])
          (encode_image_source media_type source)

let encode_tool_result_content result =
  match Llm.Tool.Result.content result with
  | [] -> Ok (Jsont.Json.string "")
  | [ Llm.Content.Text text ] -> Ok (Jsont.Json.string text)
  | content ->
      Result.map
        (fun content -> Jsont.Json.list content)
        (result_map encode_tool_result_content_item content)

let encode_tool_result result =
  Result.map
    (fun content ->
      let fields =
        [
          string_member "type" "tool_result";
          string_member "tool_use_id" (Llm.Tool.Result.call_id result);
          json_member "content" content;
        ]
      in
      let fields =
        if Llm.Tool.Result.is_error result then
          bool_member "is_error" true :: fields
        else fields
      in
      Jsont.Json.object' fields)
    (encode_tool_result_content result)

let encode_message = function
  | Llm.Message.System text | Llm.Message.Developer text ->
      Ok
        (`System
           (Jsont.Json.object'
              [ string_member "type" "text"; string_member "text" text ]))
  | Llm.Message.User content ->
      Result.map
        (fun content ->
          `Message
            (Jsont.Json.object'
               [ string_member "role" "user"; list_member "content" content ]))
        (result_map encode_user_content content)
  | Llm.Message.Assistant assistant ->
      Result.map
        (fun content ->
          `Message
            (Jsont.Json.object'
               [
                 string_member "role" "assistant"; list_member "content" content;
               ]))
        (result_map encode_assistant_part
           (Llm.Message.Assistant.parts assistant))
  | Llm.Message.Tool_result result ->
      Result.map
        (fun result ->
          `Message
            (Jsont.Json.object'
               [ string_member "role" "user"; list_member "content" [ result ] ]))
        (encode_tool_result result)

let split_messages messages =
  let rec loop system messages = function
    | [] -> Ok (List.rev system, List.rev messages)
    | message :: rest -> (
        match encode_message message with
        | Error error -> Error error
        | Ok (`System block) -> loop (block :: system) messages rest
        | Ok (`Message message) -> loop system (message :: messages) rest)
  in
  loop [] [] messages

let encode_tool tool =
  let fields =
    [
      string_member "name" (Llm.Tool.name tool);
      json_member "input_schema" (Llm.Tool.input_schema tool);
    ]
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object' fields

let encode_tool_choice tools = function
  | Llm.Request.Options.Auto ->
      if tools = [] then None
      else Some (Jsont.Json.object' [ string_member "type" "auto" ])
  | Llm.Request.Options.No_tools -> None
  | Llm.Request.Options.Required ->
      Some (Jsont.Json.object' [ string_member "type" "any" ])
  | Llm.Request.Options.Tool name ->
      Some
        (Jsont.Json.object'
           [ string_member "type" "tool"; string_member "name" name ])

let thinking_budget ~max_tokens = function
  | Llm.Request.Options.Reasoning_effort.Disabled -> assert false
  | effort ->
      if max_tokens <= 1024 then
        invalid_request
          "Anthropic thinking requires max_output_tokens greater than 1024"
      else
        let max_budget = max_tokens - 1 in
        let budget =
          match effort with
          | Llm.Request.Options.Reasoning_effort.Minimal ->
              max 1024 (max_tokens * 20 / 100)
          | Llm.Request.Options.Reasoning_effort.Low ->
              max 1024 (max_tokens * 35 / 100)
          | Llm.Request.Options.Reasoning_effort.Medium ->
              max 1024 (max_tokens * 50 / 100)
          | Llm.Request.Options.Reasoning_effort.High ->
              max 1024 (max_tokens * 70 / 100)
          | Llm.Request.Options.Reasoning_effort.Extra_high ->
              max 1024 (max_tokens * 90 / 100)
          | Llm.Request.Options.Reasoning_effort.Max -> max_budget
          | Llm.Request.Options.Reasoning_effort.Disabled -> assert false
        in
        Ok (min budget max_budget)

let encode_thinking ~max_tokens options =
  match Llm.Request.Options.reasoning_effort options with
  | None -> Ok None
  | Some Llm.Request.Options.Reasoning_effort.Disabled ->
      Ok (Some (Jsont.Json.object' [ string_member "type" "disabled" ]))
  | Some effort ->
      Result.map
        (fun budget ->
          Some
            (Jsont.Json.object'
               [
                 string_member "type" "enabled";
                 int_member "budget_tokens" budget;
               ]))
        (thinking_budget ~max_tokens effort)

let thinking_enabled options =
  match Llm.Request.Options.reasoning_effort options with
  | None | Some Llm.Request.Options.Reasoning_effort.Disabled -> false
  | Some
      ( Llm.Request.Options.Reasoning_effort.Minimal
      | Llm.Request.Options.Reasoning_effort.Low
      | Llm.Request.Options.Reasoning_effort.Medium
      | Llm.Request.Options.Reasoning_effort.High
      | Llm.Request.Options.Reasoning_effort.Extra_high
      | Llm.Request.Options.Reasoning_effort.Max ) ->
      true

let check_thinking_options options =
  if thinking_enabled options then
    match Llm.Request.Options.tool_choice options with
    | Llm.Request.Options.Required | Llm.Request.Options.Tool _ ->
        invalid_request "Anthropic thinking does not support forced tool_choice"
    | Llm.Request.Options.Auto | Llm.Request.Options.No_tools -> Ok ()
  else Ok ()

let encode_response_format = function
  | Llm.Request.Options.Text -> Ok ()
  | Llm.Request.Options.Json_schema _ ->
      unsupported "Anthropic Messages does not support response_format"

(* Prompt caching: explicit ephemeral breakpoints, three of Anthropic's four
   allowed markers, at the conventional breakpoints. The last
   tool caches the tool array, the last system block caches the tools+system
   prefix, and a marker that slides with the final message caches the whole
   conversation so far, so the next request's longer prefix reads it back.
   TTL is the provider default (5 minutes). Thinking blocks cannot carry
   markers; a request never ends on one, so the slide marker is skipped
   rather than relocated when it would land there. *)
let cache_control_member =
  json_member "cache_control"
    (Jsont.Json.object' [ string_member "type" "ephemeral" ])

let cacheable_block json =
  match string_field "type" json with
  | Some ("thinking" | "redacted_thinking") -> false
  | Some _ | None -> true

let with_cache_control json =
  match json with
  | Jsont.Object (members, meta) when cacheable_block json ->
      Jsont.Object (members @ [ cache_control_member ], meta)
  | Jsont.Object _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
  | Jsont.String _ | Jsont.Array _ ->
      json

let mark_last mark items =
  match List.rev items with
  | [] -> []
  | last :: rest -> List.rev (mark last :: rest)

let mark_last_content_block message =
  match message with
  | Jsont.Object (members, meta) ->
      let members =
        List.map
          (fun (name, value) ->
            match (fst name, value) with
            | "content", Jsont.Array (blocks, blocks_meta) ->
                ( name,
                  Jsont.Array (mark_last with_cache_control blocks, blocks_meta)
                )
            | _ -> (name, value))
          members
      in
      Jsont.Object (members, meta)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      message

let encode_request request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported
      ("Anthropic provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    let max_tokens =
      Option.value (Llm.Request.Options.max_output_tokens options) ~default:4096
    in
    match check_thinking_options options with
    | Error error -> Error error
    | Ok () -> (
        match
          encode_response_format (Llm.Request.Options.response_format options)
        with
        | Error error -> Error error
        | Ok () -> (
            match split_messages (Llm.Request.messages request) with
            | Error error -> Error error
            | Ok (system, messages) -> (
                match encode_thinking ~max_tokens options with
                | Error error -> Error error
                | Ok thinking ->
                    let tools =
                      match Llm.Request.Options.tool_choice options with
                      | Llm.Request.Options.No_tools -> []
                      | Llm.Request.Options.Auto | Llm.Request.Options.Required
                      | Llm.Request.Options.Tool _ ->
                          List.map encode_tool (Llm.Request.tools request)
                    in
                    let tools = mark_last with_cache_control tools in
                    let system = mark_last with_cache_control system in
                    let messages = mark_last mark_last_content_block messages in
                    Ok
                      {
                        Api.Messages.model = Llm.Model.id model;
                        system;
                        messages;
                        tools;
                        tool_choice =
                          encode_tool_choice tools
                            (Llm.Request.Options.tool_choice options);
                        thinking;
                        max_tokens;
                        temperature =
                          (if thinking_enabled options then None
                           else Llm.Request.Options.temperature options);
                        stream = true;
                      })))

let usage_of_json json =
  let input = Option.value (int_field "input_tokens" json) ~default:0 in
  let output = Option.value (int_field "output_tokens" json) ~default:0 in
  let cache_read =
    Option.value (int_field "cache_read_input_tokens" json) ~default:0
  in
  let cache_write =
    Option.value (int_field "cache_creation_input_tokens" json) ~default:0
  in
  Llm.Usage.make ~input ~output ~cache_read ~cache_write ()

let merge_usage left right =
  match (left, right) with
  | None, usage | usage, None -> usage
  | Some left, Some right ->
      Some
        (Llm.Usage.make
           ~input:(max left.Llm.Usage.input right.Llm.Usage.input)
           ~output:(max left.Llm.Usage.output right.Llm.Usage.output)
           ~reasoning:(max left.Llm.Usage.reasoning right.Llm.Usage.reasoning)
           ~cache_read:
             (max left.Llm.Usage.cache_read right.Llm.Usage.cache_read)
           ~cache_write:
             (max left.Llm.Usage.cache_write right.Llm.Usage.cache_write)
           ())

let parse_tool_input raw =
  match json_of_string raw with
  | Ok json -> Ok json
  | Error error ->
      Error
        (llm_error ~phase:(Llm.Error.phase error) Llm.Error.Decode
           ("Anthropic tool_use input is not valid JSON: "
          ^ Llm.Error.message error))

let stop_reason = function
  | Some "end_turn" | Some "stop_sequence" -> Some Llm.Response.Stop.end_turn
  | Some "pause_turn" -> Some (Llm.Response.Stop.other "pause_turn")
  | Some "max_tokens" -> Some Llm.Response.Stop.length
  | Some "tool_use" -> Some Llm.Response.Stop.tool_call
  | Some "refusal" -> Some Llm.Response.Stop.refusal
  | Some reason -> Some (Llm.Response.Stop.other reason)
  | None -> None

let error_kind_of_status = function
  | 400 -> Llm.Error.Invalid_request
  | 401 | 403 -> Llm.Error.Auth
  | 408 -> Llm.Error.Timeout
  | 409 -> Llm.Error.Transport
  | 413 -> Llm.Error.Context_overflow
  | 429 -> Llm.Error.Rate_limited
  | status when status >= 500 -> Llm.Error.Provider
  | _ -> Llm.Error.Provider

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

let request_id headers =
  match header_value headers "request-id" with
  | Some _ as value -> value
  | None -> header_value headers "x-request-id"

let redacted_body body =
  if String.is_empty body then None
  else
    Some
      ("<redacted Anthropic error body: "
      ^ string_of_int (String.length body)
      ^ " bytes>")

let api_error ?(phase = Llm.Error.Startup) = function
  | Api.Error.Transport message ->
      llm_error ~phase (transport_kind message) message
  | Api.Error.Decode message -> llm_error ~phase Llm.Error.Decode message
  | Api.Error.Response response ->
      let kind = error_kind_of_status response.Api.Error.status in
      let request_id = request_id response.Api.Error.headers in
      let message =
        match
          Jsont_bytesrw.decode_string Jsont.json response.Api.Error.body
        with
        | Ok json -> (
            match object_field "error" json with
            | Some error_json ->
                let type_ = string_field "type" error_json in
                let message = string_field "message" error_json in
                begin match (type_, message) with
                | Some type_, Some message -> type_ ^ ": " ^ message
                | Some type_, None -> type_
                | None, Some message -> message
                | None, None -> "Anthropic request failed"
                end
            | None ->
                Option.value
                  (string_field "message" json)
                  ~default:"Anthropic request failed")
        | Error _ ->
            if String.is_empty response.Api.Error.body then
              "Anthropic request failed"
            else "Anthropic request failed with non-JSON error body"
      in
      let redacted_body = redacted_body response.Api.Error.body in
      llm_error ~phase ~status:response.Api.Error.status ?request_id
        ?redacted_body kind message

let error_kind_of_type = function
  | Some "authentication_error" | Some "permission_error" -> Llm.Error.Auth
  | Some "rate_limit_error" | Some "overloaded_error" -> Llm.Error.Rate_limited
  | Some "invalid_request_error" -> Llm.Error.Invalid_request
  | Some _ | None -> Llm.Error.Provider

type partial = {
  id : string;
  name : string;
  mutable start_input : string option;
  mutable raw_input : string;
  mutable emitted_tool : bool;
}

let partial ~id ~name =
  { id; name; start_input = None; raw_input = ""; emitted_tool = false }

let partial_at table index ~id ~name =
  match Hashtbl.find_opt table index with
  | Some partial -> partial
  | None ->
      let partial = partial ~id ~name in
      Hashtbl.add table index partial;
      partial

type reasoning_block = {
  mutable text : string;
  mutable encrypted : string option;
  mutable signature : string option;
}

let reasoning_block () = { text = ""; encrypted = None; signature = None }

let reasoning_at table index =
  match Hashtbl.find_opt table index with
  | Some reasoning -> reasoning
  | None ->
      let reasoning = reasoning_block () in
      Hashtbl.add table index reasoning;
      reasoning

let tool_call_of_partial partial =
  let raw_input =
    if String.is_empty partial.raw_input then
      Option.value partial.start_input ~default:"{}"
    else partial.raw_input
  in
  match parse_tool_input raw_input with
  | Error error -> Error error
  | Ok input -> (
      match Llm.Tool.Call.make ~id:partial.id ~name:partial.name ~input () with
      | call -> Ok call
      | exception Invalid_argument message ->
          decode_error ("Anthropic tool_use is malformed: " ^ message))

let stream_events ~cancelled ~elapsed requested_model api_stream =
  let partials = Hashtbl.create 8 in
  let reasonings = Hashtbl.create 8 in
  let stopped_blocks = Hashtbl.create 8 in
  let pending = Queue.create () in
  let parts = ref [] in
  let part_order = ref 0 in
  let usage = ref None in
  let stop = ref None in
  let provider_stop = ref None in
  let response_id = ref None in
  let response_model = ref None in
  let reasoning_summary = Buffer.create 128 in
  let terminal = ref false in
  let emit item = Queue.add item pending in
  let fail error =
    terminal := true;
    emit (Llm.Stream.Failed error)
  in
  let add_part index part =
    let order = !part_order in
    incr part_order;
    parts := (index, order, part) :: !parts
  in
  let add_text index text =
    if not (String.is_empty text) then (
      add_part index (Llm.Message.Assistant.text_part text);
      emit (Llm.Stream.Event (Llm.Stream.Event.text_delta text)))
  in
  let add_reasoning index text =
    if not (String.is_empty text) then (
      let reasoning = reasoning_at reasonings index in
      reasoning.text <- reasoning.text ^ text;
      Buffer.add_string reasoning_summary text;
      emit (Llm.Stream.Event (Llm.Stream.Event.reasoning_summary_delta text)))
  in
  let add_signature index signature =
    if not (String.is_empty signature) then
      (reasoning_at reasonings index).signature <- Some signature
  in
  let add_redacted_reasoning index data =
    if not (String.is_empty data) then
      (reasoning_at reasonings index).encrypted <- Some data
  in
  let emit_tool_call index partial =
    if not partial.emitted_tool then
      match tool_call_of_partial partial with
      | Error error -> fail error
      | Ok call ->
          partial.emitted_tool <- true;
          add_part index (Llm.Message.Assistant.tool_call call);
          emit (Llm.Stream.Event (Llm.Stream.Event.tool_call call))
  in
  let field_string_or name ~default json =
    Option.value (string_field name json) ~default
  in
  let block_index json = Option.value (int_field "index" json) ~default:0 in
  let index_key index = string_of_int index in
  let reject_stopped index event =
    if Hashtbl.mem stopped_blocks index then (
      fail
        (stream_error Llm.Error.Decode
           ("Anthropic " ^ event ^ " after content_block_stop"));
      true)
    else false
  in
  let update_usage usage_json =
    let update = Option.map usage_of_json usage_json in
    usage := merge_usage !usage update;
    Option.iter
      (fun usage -> emit (Llm.Stream.Event (Llm.Stream.Event.usage usage)))
      !usage
  in
  let finish_response () =
    let reasoning_parts =
      Hashtbl.fold
        (fun index reasoning acc ->
          let text =
            if String.is_empty reasoning.text then None else Some reasoning.text
          in
          match (text, reasoning.encrypted, reasoning.signature) with
          | None, None, None -> acc
          | _ -> (
              match
                Llm.Message.Assistant.Reasoning.make ?text
                  ?encrypted:reasoning.encrypted ?signature:reasoning.signature
                  ()
              with
              | value ->
                  (index, -1, Llm.Message.Assistant.reasoning_part value) :: acc
              | exception Invalid_argument _ -> acc))
        reasonings []
    in
    let parts =
      !parts @ reasoning_parts
      |> List.sort
           (fun (left_index, left_order, _) (right_index, right_order, _) ->
             match Int.compare left_index right_index with
             | 0 -> Int.compare left_order right_order
             | order -> order)
      |> List.map (fun (_index, _order, part) -> part)
    in
    match parts with
    | [] -> decode_error "Anthropic response produced no assistant parts"
    | parts ->
        let assistant = Llm.Message.Assistant.make parts in
        let reasoning_summary =
          if Buffer.length reasoning_summary = 0 then []
          else [ Buffer.contents reasoning_summary ]
        in
        Ok
          (Llm.Response.make ~model:requested_model
             ?response_model:!response_model ?response_id:!response_id
             ?provider_stop:!provider_stop ?stop:!stop ?usage:!usage
             ~reasoning_summary assistant)
  in
  let handle event =
    if not !terminal then
      match event with
      | Error error -> fail (api_error ~phase:Llm.Error.Stream error)
      | Ok ({ Api.Messages.name; data = json } : Api.Messages.event) -> (
          match name with
          | "message_start" ->
              begin match object_field "message" json with
              | None -> ()
              | Some message ->
                  response_id := string_field "id" message;
                  response_model := string_field "model" message
              end;
              update_usage
                (Option.bind
                   (object_field "message" json)
                   (object_field "usage"))
          | "content_block_start" -> (
              let index = block_index json in
              if reject_stopped index "content_block_start" then ()
              else
                match object_field "content_block" json with
                | None -> ()
                | Some block -> (
                    match string_field "type" block with
                    | Some "text" ->
                        Option.iter (add_text index) (string_field "text" block)
                    | Some "thinking" ->
                        Option.iter (add_reasoning index)
                          (string_field "thinking" block)
                    | Some "redacted_thinking" ->
                        Option.iter
                          (add_redacted_reasoning index)
                          (string_field "data" block)
                    | Some "tool_use" ->
                        begin match
                          (string_field "id" block, string_field "name" block)
                        with
                        | Some id, Some name ->
                            let partial = partial_at partials index ~id ~name in
                            Option.iter
                              (fun input ->
                                partial.start_input <- Some (json_string input))
                              (object_field "input" block)
                        | None, _ ->
                            fail
                              (stream_error Llm.Error.Decode
                                 "Anthropic tool_use block is missing id")
                        | _, None ->
                            fail
                              (stream_error Llm.Error.Decode
                                 "Anthropic tool_use block is missing name")
                        end
                    | Some _ | None -> ()))
          | "content_block_delta" -> (
              let index = block_index json in
              if reject_stopped index "content_block_delta" then ()
              else
                match object_field "delta" json with
                | None -> ()
                | Some delta -> (
                    match string_field "type" delta with
                    | Some "text_delta" ->
                        Option.iter (add_text index) (string_field "text" delta)
                    | Some "thinking_delta" ->
                        Option.iter (add_reasoning index)
                          (string_field "thinking" delta)
                    | Some "input_json_delta" ->
                        let key = index_key index in
                        begin match Hashtbl.find_opt partials index with
                        | None ->
                            fail
                              (stream_error Llm.Error.Decode
                                 "Anthropic input_json_delta without \
                                  content_block_start")
                        | Some partial ->
                            let delta =
                              field_string_or "partial_json" ~default:"" delta
                            in
                            partial.raw_input <- partial.raw_input ^ delta;
                            if not (String.is_empty delta) then
                              emit
                                (Llm.Stream.Event
                                   (Llm.Stream.Event.tool_input_delta
                                      (Llm.Stream.Event.Tool_input.make ~key
                                         ~call_id:partial.id ~name:partial.name
                                         ~input_delta:delta ())))
                        end
                    | Some "signature_delta" ->
                        Option.iter (add_signature index)
                          (string_field "signature" delta)
                    | Some _ | None -> ()))
          | "content_block_stop" ->
              let index = block_index json in
              if Hashtbl.mem stopped_blocks index then
                fail
                  (stream_error Llm.Error.Decode
                     "Anthropic duplicate content_block_stop")
              else (
                Hashtbl.add stopped_blocks index ();
                Option.iter (emit_tool_call index)
                  (Hashtbl.find_opt partials index))
          | "message_delta" ->
              update_usage (object_field "usage" json);
              begin match object_field "delta" json with
              | None -> ()
              | Some delta ->
                  provider_stop := string_field "stop_reason" delta;
                  stop := stop_reason !provider_stop
              end
          | "message_stop" ->
              terminal := true;
              begin match finish_response () with
              | Error error -> emit (Llm.Stream.Failed error)
              | Ok response ->
                  Log.info (fun m ->
                      let usage =
                        Option.value
                          (Llm.Response.usage response)
                          ~default:Llm.Usage.zero
                      in
                      m
                        "request finished model=%s stop=%s input=%d output=%d \
                         duration=%.0fms"
                        (Llm.Model.id requested_model)
                        (Option.fold ~none:"none" ~some:Llm.Response.Stop.label
                           (Llm.Response.stop response))
                        usage.Llm.Usage.input usage.Llm.Usage.output
                        (elapsed ()));
                  emit (Llm.Stream.Finished response)
              end
          | "error" ->
              let message =
                match object_field "error" json with
                | Some error_json -> (
                    match
                      ( string_field "type" error_json,
                        string_field "message" error_json )
                    with
                    | Some type_, Some message -> type_ ^ ": " ^ message
                    | Some type_, None -> type_
                    | None, Some message -> message
                    | None, None -> "Anthropic stream error")
                | None ->
                    Option.value
                      (string_field "message" json)
                      ~default:"Anthropic stream error"
              in
              let kind =
                error_kind_of_type
                  (Option.bind
                     (object_field "error" json)
                     (string_field "type"))
              in
              fail (stream_error kind message)
          | "ping" -> ()
          | _ -> ())
  in
  let rec next () =
    if not (Queue.is_empty pending) then Some (Queue.take pending)
    else if !terminal then None
    else if cancelled () then (
      terminal := true;
      Api.Messages.close api_stream;
      Log.debug (fun m ->
          m "request cancelled model=%s" (Llm.Model.id requested_model));
      Some (Llm.Stream.Failed (cancelled_error ~phase:Llm.Error.Stream ())))
    else
      match Api.Messages.next api_stream with
      | Some event ->
          handle event;
          next ()
      | None ->
          terminal := true;
          Log.debug (fun m ->
              m "stream ended without message_stop model=%s"
                (Llm.Model.id requested_model));
          Some
            (Llm.Stream.Failed
               (stream_error Llm.Error.Malformed_stream
                  "Anthropic stream ended without message_stop"))
  in
  Llm.Stream.make ~close:(fun () -> Api.Messages.close api_stream) next

let stream ~sw ~env config credential ~cancelled request =
  if cancelled () then Error (cancelled_error ())
  else
    let model = Llm.Request.model request in
    match encode_request request with
    | Error error -> Error error
    | Ok api_request -> (
        Log.info (fun m -> m "request started model=%s" (Llm.Model.id model));
        let clock = env#clock in
        let started = Eio.Time.now clock in
        let elapsed () = (Eio.Time.now clock -. started) *. 1000. in
        let api_client =
          Api.Client.make config ~sw ~env
            ~auth:(Credential.api_auth credential)
            ()
        in
        match Api.Messages.create_stream api_client api_request with
        | Error error -> Error (api_error error)
        | Ok api_stream ->
            Ok (stream_events ~cancelled ~elapsed model api_stream))

let client ~sw ~env ?(config = Config.default) ~credential () =
  let accepts model =
    Llm.Provider.equal provider (Llm.Model.provider model)
    && Llm.Model.Api.equal api (Llm.Model.api model)
  in
  Llm.Client.make ~provider ~accepts ~run:(stream ~sw ~env config credential) ()
