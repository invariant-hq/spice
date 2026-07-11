(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Spice_llm
module Options = Llm.Request.Options

let log_src = Logs.Src.create "spice.llm.ollama" ~doc:"Ollama provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( let* ) = Result.bind
let provider = Llm.Provider.make "ollama"
let api = Llm.Model.Api.make "chat-completions"
let model id = Llm.Model.make ~provider ~api ~id
let invalid fn message = invalid_arg ("Spice_llm_ollama." ^ fn ^ ": " ^ message)

let contains_newline value =
  String.exists (function '\n' | '\r' -> true | _ -> false) value

module Config = struct
  type t = { base_url : string }

  let default_base_url = "http://127.0.0.1:11434"

  let make ?(base_url = default_base_url) () =
    if String.is_empty base_url then
      invalid "Config.make" "base_url must not be empty";
    if contains_newline base_url then
      invalid "Config.make" "base_url must not contain newline";
    let base_url = String.drop_last_while (Char.equal '/') base_url in
    if String.is_empty base_url then
      invalid "Config.make" "base_url must not be only slashes";
    { base_url }

  let default = make ()
  let base_url t = t.base_url
end

module Credential = struct
  type t = Api_key of string | Bearer of string

  let check fn value =
    if String.is_empty value then invalid fn "value must not be empty";
    if contains_newline value then invalid fn "value must not contain newline"

  let api_key key =
    check "Credential.api_key" key;
    Api_key key

  let bearer token =
    check "Credential.bearer" token;
    Bearer token

  (* Both kinds authenticate as a bearer token: the daemon (and every
     OpenAI-compatible server behind the same endpoint shape) reads
     [Authorization: Bearer]. *)
  let header = function
    | Api_key value | Bearer value -> ("authorization", "Bearer " ^ value)
end

let llm_error ?(phase = Llm.Error.Startup) ?status kind message =
  Llm.Error.make ~kind ~phase ~provider ?status message

let unsupported message = Error (llm_error Llm.Error.Unsupported message)
let stream_error kind message = llm_error ~phase:Llm.Error.Stream kind message

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "Ollama request cancelled"

(* Request encoding: provider-neutral messages to chat-completions JSON. *)

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let list_member name value = json_member name (Jsont.Json.list value)

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid "json_string" ("JSON encode failed: " ^ message)

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok _ as ok -> ok
  | Error message -> Error message

let text_of_content ~what blocks =
  let rec loop acc = function
    | [] -> Ok (String.concat "\n" (List.rev acc))
    | Llm.Content.Text text :: rest -> loop (text :: acc) rest
    | Llm.Content.Media _ :: _ ->
        unsupported ("Ollama models support text " ^ what ^ " only")
  in
  loop [] blocks

let role_message role content =
  Jsont.Json.object'
    [ string_member "role" role; string_member "content" content ]

let encode_assistant assistant =
  let texts, calls =
    List.fold_left
      (fun (texts, calls) part ->
        match part with
        | Llm.Message.Assistant.Text text -> (text :: texts, calls)
        | Llm.Message.Assistant.Tool_call call -> (texts, call :: calls)
        | Llm.Message.Assistant.Reasoning _ ->
            (* Reasoning is not replayable over chat completions; models
               re-derive it. *)
            (texts, calls))
      ([], [])
      (Llm.Message.Assistant.parts assistant)
  in
  let texts = List.rev texts and calls = List.rev calls in
  if List.is_empty texts && List.is_empty calls then []
  else
    let encode_call call =
      Jsont.Json.object'
        [
          string_member "id" (Llm.Tool.Call.id call);
          string_member "type" "function";
          json_member "function"
            (Jsont.Json.object'
               [
                 string_member "name" (Llm.Tool.Call.name call);
                 string_member "arguments"
                   (json_string (Llm.Tool.Call.input call));
               ]);
        ]
    in
    let fields = [ string_member "role" "assistant" ] in
    let fields =
      match texts with
      | [] -> fields
      | texts -> string_member "content" (String.concat "\n" texts) :: fields
    in
    let fields =
      match calls with
      | [] -> fields
      | calls -> list_member "tool_calls" (List.map encode_call calls) :: fields
    in
    [ Jsont.Json.object' (List.rev fields) ]

let encode_message = function
  | Llm.Message.System text | Llm.Message.Developer text ->
      (* Local chat templates know [system]; [developer] is an OpenAI-ism. *)
      Ok [ role_message "system" text ]
  | Llm.Message.User content ->
      let* text = text_of_content ~what:"user content" content in
      Ok [ role_message "user" text ]
  | Llm.Message.Assistant assistant -> Ok (encode_assistant assistant)
  | Llm.Message.Tool_result result ->
      let* text =
        text_of_content ~what:"tool results" (Llm.Tool.Result.content result)
      in
      Ok
        [
          Jsont.Json.object'
            [
              string_member "role" "tool";
              string_member "tool_call_id" (Llm.Tool.Result.call_id result);
              string_member "content" text;
            ];
        ]

let encode_tool tool =
  let fields =
    [
      string_member "name" (Llm.Tool.name tool);
      json_member "parameters" (Llm.Tool.input_schema tool);
    ]
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object'
    [
      string_member "type" "function";
      json_member "function" (Jsont.Json.object' (List.rev fields));
    ]

let encode_tool_choice = function
  | Options.Auto -> None
  | Options.No_tools -> Some (Jsont.Json.string "none")
  | Options.Required -> Some (Jsont.Json.string "required")
  | Options.Tool name ->
      Some
        (Jsont.Json.object'
           [
             string_member "type" "function";
             json_member "function"
               (Jsont.Json.object' [ string_member "name" name ]);
           ])

let encode_response_format = function
  | Options.Text -> None
  | Options.Json_schema { name; schema; strict } ->
      Some
        (Jsont.Json.object'
           [
             string_member "type" "json_schema";
             json_member "json_schema"
               (Jsont.Json.object'
                  [
                    string_member "name" name;
                    json_member "schema" schema;
                    bool_member "strict" strict;
                  ]);
           ])

let encode_reasoning_effort = function
  | None | Some Options.Reasoning_effort.Disabled -> Ok None
  | Some Options.Reasoning_effort.Low -> Ok (Some "low")
  | Some Options.Reasoning_effort.Medium -> Ok (Some "medium")
  | Some Options.Reasoning_effort.High -> Ok (Some "high")
  | Some
      ( Options.Reasoning_effort.Minimal | Options.Reasoning_effort.Extra_high
      | Options.Reasoning_effort.Max ) ->
      unsupported "Ollama models support reasoning effort low, medium, or high"

let result_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Ok mapped -> loop (mapped :: acc) rest
        | Error _ as error -> error)
  in
  loop [] values

let encode_request request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported
      ("Ollama provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    let* messages_nested =
      result_map encode_message (Llm.Request.messages request)
    in
    let* reasoning_effort =
      encode_reasoning_effort (Options.reasoning_effort options)
    in
    Ok
      {
        Api.Chat.model = Llm.Model.id model;
        messages = List.concat messages_nested;
        tools = List.map encode_tool (Llm.Request.tools request);
        tool_choice = encode_tool_choice (Options.tool_choice options);
        response_format =
          encode_response_format (Options.response_format options);
        reasoning_effort;
        max_tokens = Options.max_output_tokens options;
        temperature = Options.temperature options;
      }

(* Stream decoding: chat-completions chunks to provider-neutral events. *)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some _ | None -> None

let int_field name json =
  match object_field name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (Float.to_int value)
  | Some _ | None -> None

let list_field name json =
  match object_field name json with
  | Some (Jsont.Array (values, _)) -> Some values
  | Some _ | None -> None

let usage_of_json json =
  let prompt = Option.value (int_field "prompt_tokens" json) ~default:0 in
  let completion =
    Option.value (int_field "completion_tokens" json) ~default:0
  in
  let cache_read =
    match object_field "prompt_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "cached_tokens" details) ~default:0
  in
  let reasoning =
    match object_field "completion_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "reasoning_tokens" details) ~default:0
  in
  let input = max 0 (prompt - cache_read) in
  let output = max 0 (completion - reasoning) in
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ()

let api_error ?(phase = Llm.Error.Startup) = function
  | Api.Error.Transport message -> llm_error ~phase Llm.Error.Transport message
  | Api.Error.Decode message -> llm_error ~phase Llm.Error.Decode message
  | Api.Error.Response response ->
      let kind =
        match response.Api.Error.status with
        | 400 -> Llm.Error.Invalid_request
        | 413 -> Llm.Error.Context_overflow
        | status when status >= 500 -> Llm.Error.Provider
        | _ -> Llm.Error.Provider
      in
      let message =
        match
          Jsont_bytesrw.decode_string Jsont.json response.Api.Error.body
        with
        | Ok json -> (
            match object_field "error" json with
            | Some error_json ->
                Option.value
                  (string_field "message" error_json)
                  ~default:"Ollama request failed"
            | None ->
                Option.value
                  (string_field "message" json)
                  ~default:"Ollama request failed")
        | Error _ -> "Ollama request failed"
      in
      llm_error ~phase ~status:response.Api.Error.status kind message

type partial = {
  mutable call_id : string option;
  mutable name : string option;
  input : Buffer.t;
}

let stream_events ~cancelled requested_model api_stream =
  let partials : (int, partial) Hashtbl.t = Hashtbl.create 4 in
  let call_order = ref [] in
  let content = Buffer.create 256 in
  let reasoning = Buffer.create 256 in
  let finish_reason = ref None in
  let response_model = ref None in
  let response_id = ref None in
  let usage = ref None in
  let pending = Queue.create () in
  let terminal = ref false in
  let emit item = Queue.add item pending in
  let fail error =
    terminal := true;
    emit (Llm.Stream.Failed error)
  in
  let partial_at index =
    match Hashtbl.find_opt partials index with
    | Some partial -> partial
    | None ->
        let partial =
          { call_id = None; name = None; input = Buffer.create 64 }
        in
        Hashtbl.add partials index partial;
        call_order := index :: !call_order;
        partial
  in
  let record_ids json =
    (match (!response_model, string_field "model" json) with
    | None, (Some _ as value) -> response_model := value
    | _ -> ());
    match (!response_id, string_field "id" json) with
    | None, (Some _ as value) -> response_id := value
    | _ -> ()
  in
  let handle_tool_call_delta json =
    let index = Option.value (int_field "index" json) ~default:0 in
    let partial = partial_at index in
    (match string_field "id" json with
    | Some id when not (String.is_empty id) -> partial.call_id <- Some id
    | Some _ | None -> ());
    match object_field "function" json with
    | None -> ()
    | Some fn -> (
        (match string_field "name" fn with
        | Some name when not (String.is_empty name) -> partial.name <- Some name
        | Some _ | None -> ());
        match string_field "arguments" fn with
        | Some delta when not (String.is_empty delta) ->
            Buffer.add_string partial.input delta;
            emit
              (Llm.Stream.Event
                 (Llm.Stream.Event.tool_input_delta
                    (Llm.Stream.Event.Tool_input.make ~key:(string_of_int index)
                       ?call_id:partial.call_id ?name:partial.name
                       ~input_delta:delta ())))
        | Some _ | None -> ())
  in
  let handle_delta delta =
    (match string_field "content" delta with
    | Some text when not (String.is_empty text) ->
        Buffer.add_string content text;
        emit (Llm.Stream.Event (Llm.Stream.Event.text_delta text))
    | Some _ | None -> ());
    (match
       match string_field "reasoning_content" delta with
       | Some _ as value -> value
       | None -> string_field "reasoning" delta
     with
    | Some text when not (String.is_empty text) ->
        Buffer.add_string reasoning text;
        emit (Llm.Stream.Event (Llm.Stream.Event.reasoning_summary_delta text))
    | Some _ | None -> ());
    match list_field "tool_calls" delta with
    | None -> ()
    | Some calls -> List.iter handle_tool_call_delta calls
  in
  let handle_chunk json =
    record_ids json;
    (match object_field "usage" json with
    | Some (Jsont.Object _ as usage_json) ->
        let value = usage_of_json usage_json in
        usage := Some value;
        emit (Llm.Stream.Event (Llm.Stream.Event.usage value))
    | Some _ | None -> ());
    match list_field "choices" json with
    | None | Some [] -> ()
    | Some (choice :: _) -> (
        (match string_field "finish_reason" choice with
        | Some reason when not (String.is_empty reason) ->
            finish_reason := Some reason
        | Some _ | None -> ());
        match object_field "delta" choice with
        | None -> ()
        | Some delta -> handle_delta delta)
  in
  let finalize_call index =
    let partial = Hashtbl.find partials index in
    match partial.name with
    | None ->
        Error
          (stream_error Llm.Error.Decode
             "Ollama stream tool call is missing a function name")
    | Some name -> (
        let id =
          match partial.call_id with
          | Some id -> id
          | None -> Printf.sprintf "local_call_%d" index
        in
        let raw_input =
          match Buffer.contents partial.input with "" -> "{}" | raw -> raw
        in
        match json_of_string raw_input with
        | Error message ->
            Error
              (stream_error Llm.Error.Decode
                 ("Ollama tool-call arguments are not valid JSON: " ^ message))
        | Ok input -> (
            match Llm.Tool.Call.make ~id ~name ~input () with
            | call -> Ok call
            | exception Invalid_argument message ->
                Error
                  (stream_error Llm.Error.Decode
                     ("Ollama tool call is malformed: " ^ message))))
  in
  let finalize () =
    terminal := true;
    match result_map finalize_call (List.rev !call_order) with
    | Error error -> emit (Llm.Stream.Failed error)
    | Ok calls ->
        List.iter
          (fun call ->
            emit (Llm.Stream.Event (Llm.Stream.Event.tool_call call)))
          calls;
        let parts = [] in
        let parts =
          match Buffer.contents content with
          | "" -> parts
          | text -> Llm.Message.Assistant.text_part text :: parts
        in
        let parts =
          match Buffer.contents reasoning with
          | "" -> parts
          | text ->
              Llm.Message.Assistant.reasoning_part
                (Llm.Message.Assistant.Reasoning.make ~text ())
              :: parts
        in
        let parts =
          List.rev parts @ List.map Llm.Message.Assistant.tool_call calls
        in
        let assistant =
          match parts with
          | [] -> Llm.Message.Assistant.empty
          | parts -> Llm.Message.Assistant.make parts
        in
        let stop =
          match !finish_reason with
          | Some "stop" | None ->
              if List.is_empty calls then Some Llm.Response.Stop.end_turn
              else Some Llm.Response.Stop.tool_call
          | Some "tool_calls" -> Some Llm.Response.Stop.tool_call
          | Some "length" -> Some Llm.Response.Stop.length
          | Some "content_filter" -> Some Llm.Response.Stop.content_filter
          | Some other -> Llm.Response.Stop.of_label other
        in
        let response =
          Llm.Response.make ~model:requested_model
            ?response_model:!response_model ?response_id:!response_id
            ?provider_stop:!finish_reason ?stop ?usage:!usage assistant
        in
        Log.info (fun m ->
            let usage = Option.value !usage ~default:Llm.Usage.zero in
            m "request finished model=%s stop=%s input=%d output=%d"
              (Llm.Model.id requested_model)
              (Option.value !finish_reason ~default:"none")
              usage.Llm.Usage.input usage.Llm.Usage.output);
        emit (Llm.Stream.Finished response)
  in
  let rec next () =
    if not (Queue.is_empty pending) then Some (Queue.take pending)
    else if !terminal then None
    else if cancelled () then begin
      Log.debug (fun m ->
          m "request cancelled model=%s" (Llm.Model.id requested_model));
      terminal := true;
      Api.Chat.close api_stream;
      Some (Llm.Stream.Failed (cancelled_error ~phase:Llm.Error.Stream ()))
    end
    else
      match Api.Chat.next api_stream with
      | Some (Ok (Api.Chat.Chunk json)) ->
          handle_chunk json;
          next ()
      | Some (Ok Api.Chat.Done) ->
          finalize ();
          next ()
      | Some (Error error) ->
          fail (api_error ~phase:Llm.Error.Stream error);
          next ()
      | None ->
          if Option.is_some !finish_reason then begin
            (* Some servers end the body without a [DONE] sentinel. *)
            finalize ();
            next ()
          end
          else begin
            terminal := true;
            Some
              (Llm.Stream.Failed
                 (stream_error Llm.Error.Malformed_stream
                    "Ollama stream ended without completion"))
          end
  in
  Llm.Stream.make ~close:(fun () -> Api.Chat.close api_stream) next

let client ~env ?(config = Config.default) ?credential () =
  let accepts model =
    Llm.Provider.equal provider (Llm.Model.provider model)
    && Llm.Model.Api.equal api (Llm.Model.api model)
  in
  let headers = Option.map Credential.header credential |> Option.to_list in
  let run ~cancelled ~on_event request =
    if cancelled () then Error (cancelled_error ())
    else
      Eio.Switch.run ~name:"ollama.request" @@ fun sw ->
      let api_client =
        Api.Client.make ~headers ~base_url:(Config.base_url config) ~sw ~env ()
      in
      let model = Llm.Request.model request in
      let* api_request = encode_request request in
      Log.info (fun m -> m "request started model=%s" (Llm.Model.id model));
      match Api.Chat.create_stream api_client api_request with
      | Error error -> Error (api_error error)
      | Ok api_stream ->
          Llm.Stream.iter_events
            (stream_events ~cancelled model api_stream)
            ~f:on_event
  in
  Llm.Client.make ~provider ~accepts ~run ()
