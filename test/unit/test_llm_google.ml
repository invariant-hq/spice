(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Llm = Spice_llm
module Google = Spice_llm_google
module Json = Jsont.Json

type recorded_request = {
  request_line : string;
  headers : (string * string) list;
  body : string;
}

let expect_stream_ok msg = function
  | Ok value -> value
  | Error (events, error) ->
      ignore events;
      failf "%s: %a" msg Llm.Error.pp error

let expect_stream_error msg = function
  | Ok value ->
      ignore value;
      failf "%s: expected stream error" msg
  | Error value -> value

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> failf "JSON encode failed: %s" message

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> json
  | Error message -> failf "JSON decode failed: %s" message

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let field msg name json =
  match object_field name json with
  | Some value -> value
  | None -> failf "%s: missing JSON field %s" msg name

let has_field name json = Option.is_some (object_field name json)

let string_field msg name json =
  match field msg name json with
  | Jsont.String (value, _) -> value
  | value ->
      failf "%s: expected string field %s, got %s" msg name (json_string value)

let bool_field msg name json =
  match field msg name json with
  | Jsont.Bool (value, _) -> value
  | value ->
      failf "%s: expected bool field %s, got %s" msg name (json_string value)

let list_field msg name json =
  match field msg name json with
  | Jsont.Array (items, _) -> items
  | value ->
      failf "%s: expected array field %s, got %s" msg name (json_string value)

let header request name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    request.headers

let request_body request = json_of_string request.body

let only_request = function
  | [ request ] -> request
  | requests -> failf "expected one request, got %d" (List.length requests)

let rec waitpid_nointr flags pid =
  match Unix.waitpid flags pid with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr flags pid

let strip_cr line =
  let len = String.length line in
  if len > 0 && Char.equal line.[len - 1] '\r' then
    String.take_first (len - 1) line
  else line

let split_header line =
  match String.split_first ~sep:":" line with
  | None -> (String.lowercase_ascii line, "")
  | Some (name, value) ->
      let name = String.lowercase_ascii name in
      let value = String.trim value in
      (name, value)

let read_http_request fd =
  let ic = Unix.in_channel_of_descr fd in
  let request_line = input_line ic |> strip_cr in
  let rec read_headers acc =
    let line = input_line ic |> strip_cr in
    if String.is_empty line then List.rev acc
    else read_headers (split_header line :: acc)
  in
  let headers = read_headers [] in
  let content_length =
    match header { request_line; headers; body = "" } "content-length" with
    | None -> 0
    | Some value -> Option.value (int_of_string_opt value) ~default:0
  in
  let body = really_input_string ic content_length in
  { request_line; headers; body }

let http_response ?(headers = []) ?(content_type = "application/json") status
    body =
  let reason = if status = 200 then "OK" else "Status" in
  let headers =
    ("Content-Type", content_type)
    :: ("Content-Length", string_of_int (String.length body))
    :: ("Connection", "close") :: headers
  in
  let header_text =
    headers
    |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
    |> String.concat ""
  in
  Printf.sprintf "HTTP/1.1 %d %s\r\n%s\r\n%s" status reason header_text body

let read_recorded_requests path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let rec loop acc =
        match Marshal.from_channel ic with
        | request -> loop (request :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let with_google_server respond f =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket 8;
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (address, port) ->
        ignore address;
        port
    | Unix.ADDR_UNIX path ->
        failf "expected inet socket, got unix socket %s" path
  in
  let requests_path = Filename.temp_file "spice-google-requests" ".bin" in
  match Unix.fork () with
  | 0 -> (
      match
        let oc = open_out_bin requests_path in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
            let rec serve index =
              let client, address = Unix.accept socket in
              ignore address;
              Fun.protect
                ~finally:(fun () -> Unix.close client)
                (fun () ->
                  let request = read_http_request client in
                  Marshal.to_channel oc request [];
                  flush oc;
                  let response = respond index request in
                  let bytes = Bytes.of_string response in
                  ignore (Unix.write client bytes 0 (Bytes.length bytes)));
              serve (index + 1)
            in
            serve 0)
      with
      | () -> exit 0
      | exception exn ->
          prerr_endline (Printexc.to_string exn);
          exit 2)
  | pid ->
      Unix.close socket;
      Fun.protect
        ~finally:(fun () ->
          begin match Unix.kill pid Sys.sigterm with
          | () -> ()
          | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()
          end;
          ignore (waitpid_nointr [] pid);
          Sys.remove requests_path)
        (fun () ->
          let result = f port in
          (result, read_recorded_requests requests_path))

let sse_response events =
  http_response ~content_type:"text/event-stream" 200 (String.concat "" events)

let sse_event json = "data: " ^ json_string json ^ "\r\n\r\n"

let text_stream text =
  sse_response
    [
      sse_event
        (json_object
           [
             ( "candidates",
               Json.list
                 [
                   json_object
                     [
                       ( "content",
                         json_object
                           [
                             ("role", Json.string "model");
                             ( "parts",
                               Json.list
                                 [ json_object [ ("text", Json.string text) ] ]
                             );
                           ] );
                       ("finishReason", Json.string "STOP");
                     ];
                 ] );
             ( "usageMetadata",
               json_object
                 [
                   ("promptTokenCount", Json.int 5);
                   ("candidatesTokenCount", Json.int 1);
                 ] );
             ("modelVersion", Json.string "gemini-test");
             ("responseId", Json.string "resp_1");
           ]);
    ]

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", Json.list [ Json.string "path" ]);
    ]

let user_transcript text =
  Llm.Transcript.of_list_exn [ Llm.Message.user_text text ]

let request ?prelude ?tools ?options ?transcript () =
  let transcript = Option.value transcript ~default:(user_transcript "hello") in
  Llm.Request.make_exn
    ~model:(Google.model "gemini-test")
    ?prelude ?tools ?options transcript

let run_stream ?(cancelled = fun () -> false) ?config
    ?(credential = Google.Credential.api_key "google-test-key") ?on_event port
    request =
  let base_url = "http://127.0.0.1:" ^ string_of_int port in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config =
    match config with
    | Some config -> config
    | None -> Google.Config.make ~base_url ~max_retries:0 ()
  in
  let client = Google.client ~sw ~env ~config ~credential () in
  match Llm.Client.stream ~cancelled client request with
  | Error error -> Error ([], error)
  | Ok stream ->
      let rec loop events =
        match Llm.Stream.next stream with
        | None ->
            Error
              ( events,
                Llm.Error.make ~kind:Llm.Error.Malformed_stream
                  "stream ended without terminal item" )
        | Some (Llm.Stream.Event event) ->
            Option.iter (fun f -> f event) on_event;
            loop (event :: events)
        | Some (Llm.Stream.Finished response) -> Ok (List.rev events, response)
        | Some (Llm.Stream.Failed error) -> Error (List.rev events, error)
      in
      loop []

let model_config_and_credentials () =
  let model = Google.model "gemini-test" in
  check "model provider"
    (Llm.Provider.equal (Llm.Model.provider model) Google.provider);
  check "model api" (Llm.Model.Api.equal (Llm.Model.api model) Google.api);
  equal string ~msg:"model id" "gemini-test" (Llm.Model.id model);
  expect_invalid_arg "model id cannot be empty" (fun () ->
      ignore (Google.model ""));
  let config =
    Google.Config.make ~base_url:"https://google.example.test///" ~timeout_s:5.
      ~max_retries:2 ()
  in
  equal (option string) ~msg:"base_url trimmed"
    (Some "https://google.example.test")
    (Google.Config.base_url config);
  check "timeout" (Google.Config.timeout_s config = Some 5.);
  equal (option int) ~msg:"max retries" (Some 2)
    (Google.Config.max_retries config);
  expect_invalid_arg "base_url cannot normalize empty" (fun () ->
      ignore (Google.Config.make ~base_url:"///" ()));
  expect_invalid_arg "base_url cannot contain newline" (fun () ->
      ignore (Google.Config.make ~base_url:"https://x\nbad" ()));
  expect_invalid_arg "timeout must be positive" (fun () ->
      ignore (Google.Config.make ~timeout_s:0. ()));
  expect_invalid_arg "max_retries cannot be negative" (fun () ->
      ignore (Google.Config.make ~max_retries:(-1) ()));
  ignore (Google.Credential.api_key "google-test-key" : Google.Credential.t);
  expect_invalid_arg "api key cannot be empty" (fun () ->
      ignore (Google.Credential.api_key ""));
  expect_invalid_arg "api key cannot contain newline" (fun () ->
      ignore (Google.Credential.api_key "key\nbad"))

let maximal_request_encoding () =
  let call =
    Llm.Tool.Call.make ~id:"call_1" ~name:"read_file"
      ~input:(json_object [ ("path", Json.string "a.ml") ])
      ()
  in
  let transcript =
    Llm.Transcript.of_list_exn
      [
        Llm.Message.system "system";
        Llm.Message.developer "developer";
        Llm.Message.user
          [
            Llm.Content.text "inspect this";
            Llm.Content.media ~media_type:"image/png" (`Base64 "abcd");
          ];
        Llm.Message.assistant
          (Llm.Message.Assistant.make
             [
               Llm.Message.Assistant.text_part "checking";
               Llm.Message.Assistant.tool_call call;
             ]);
        Llm.Message.tool_result (Llm.Tool.Result.text call "file contents");
      ]
  in
  let tool =
    Llm.Tool.make ~name:"read_file" ~description:"Read a file."
      ~input_schema:schema ()
  in
  let options =
    Llm.Request.Options.make ~tool_choice:(Llm.Request.Options.Tool "read_file")
      ~max_output_tokens:8192 ~temperature:0.25
      ~reasoning_effort:Llm.Request.Options.Reasoning_effort.High ()
  in
  let prelude =
    match
      Llm.Request.Prelude.make
        [
          Llm.Message.system "host system";
          Llm.Message.developer "host developer";
        ]
    with
    | Ok prelude -> prelude
    | Error error -> failf "prelude failed: %a" Llm.Request.Error.pp error
  in
  let result, requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        text_stream "ok")
      (fun port ->
        run_stream port
          (request ~prelude ~tools:[ tool ] ~options ~transcript ()))
  in
  ignore (expect_stream_ok "stream" result);
  let request = only_request requests in
  equal string ~msg:"method and path"
    "POST /models/gemini-test:streamGenerateContent?alt=sse HTTP/1.1"
    request.request_line;
  equal (option string) ~msg:"api key" (Some "google-test-key")
    (header request "x-goog-api-key");
  let body = request_body request in
  check "model omitted from body" (not (has_field "model" body));
  let system =
    list_field "system" "parts" (field "body" "systemInstruction" body)
  in
  equal int ~msg:"system block count" 4 (List.length system);
  equal string ~msg:"host system text" "host system"
    (string_field "system" "text" (List.nth system 0));
  equal string ~msg:"host developer text" "host developer"
    (string_field "developer" "text" (List.nth system 1));
  equal string ~msg:"system text" "system"
    (string_field "system" "text" (List.nth system 2));
  equal string ~msg:"developer text" "developer"
    (string_field "developer" "text" (List.nth system 3));
  let contents = list_field "body" "contents" body in
  equal int ~msg:"content count" 3 (List.length contents);
  equal string ~msg:"user role" "user"
    (string_field "user" "role" (List.nth contents 0));
  let user_parts = list_field "user" "parts" (List.nth contents 0) in
  equal string ~msg:"user text" "inspect this"
    (string_field "user text" "text" (List.nth user_parts 0));
  let inline = field "image" "inlineData" (List.nth user_parts 1) in
  equal string ~msg:"image media type" "image/png"
    (string_field "image" "mimeType" inline);
  equal string ~msg:"image data" "abcd" (string_field "image" "data" inline);
  let assistant_parts = list_field "assistant" "parts" (List.nth contents 1) in
  equal string ~msg:"assistant role" "model"
    (string_field "assistant" "role" (List.nth contents 1));
  equal string ~msg:"assistant text" "checking"
    (string_field "assistant text" "text" (List.nth assistant_parts 0));
  let function_call =
    field "function call" "functionCall" (List.nth assistant_parts 1)
  in
  equal string ~msg:"function call name" "read_file"
    (string_field "function call" "name" function_call);
  equal string ~msg:"first call gets the synthetic thought signature"
    "skip_thought_signature_validator"
    (string_field "function call" "thoughtSignature"
       (List.nth assistant_parts 1));
  let tool_result =
    List.hd (list_field "tool result" "parts" (List.nth contents 2))
  in
  let function_response = field "tool result" "functionResponse" tool_result in
  equal string ~msg:"function response name" "read_file"
    (string_field "tool result" "name" function_response);
  let tools = list_field "body" "tools" body in
  equal int ~msg:"tool envelope count" 1 (List.length tools);
  let declarations = list_field "tool" "functionDeclarations" (List.hd tools) in
  equal string ~msg:"tool name" "read_file"
    (string_field "tool" "name" (List.hd declarations));
  let tool_config = field "body" "toolConfig" body in
  let function_calling =
    field "tool config" "functionCallingConfig" tool_config
  in
  equal string ~msg:"tool choice mode" "ANY"
    (string_field "tool choice" "mode" function_calling);
  begin match
    List.hd (list_field "tool choice" "allowedFunctionNames" function_calling)
  with
  | Jsont.String (value, _) ->
      equal string ~msg:"allowed tool" "read_file" value
  | value -> failf "allowed tool: expected string, got %s" (json_string value)
  end

let projected_tool_schema_encoding () =
  let input_schema =
    json_object
      [
        ("type", Json.string "object");
        ( "properties",
          json_object
            [
              ( "count",
                json_object
                  [
                    ("type", Json.string "integer");
                    ("enum", Json.list [ Json.int 1; Json.int 2 ]);
                    ( "properties",
                      json_object
                        [
                          ("x", json_object [ ("type", Json.string "string") ]);
                        ] );
                    ("required", Json.list [ Json.string "x" ]);
                  ] );
              ( "tags",
                json_object
                  [ ("type", Json.string "array"); ("items", json_object []) ]
              );
              ( "maybe",
                json_object
                  [
                    ( "type",
                      Json.list [ Json.string "null"; Json.string "string" ] );
                  ] );
            ] );
        ("required", Json.list [ Json.string "count"; Json.string "missing" ]);
        ("additionalProperties", Json.bool false);
      ]
  in
  let tool =
    Llm.Tool.make ~name:"shape" ~description:"Inspect a shape." ~input_schema ()
  in
  let result, requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        text_stream "ok")
      (fun port -> run_stream port (request ~tools:[ tool ] ()))
  in
  ignore (expect_stream_ok "stream" result);
  let body = request_body (only_request requests) in
  let tools = list_field "body" "tools" body in
  let declarations = list_field "tool" "functionDeclarations" (List.hd tools) in
  let declaration = List.hd declarations in
  let parameters = field "tool" "parameters" declaration in
  check "unsupported additionalProperties removed"
    (not (has_field "additionalProperties" parameters));
  equal string ~msg:"root type" "object"
    (string_field "parameters" "type" parameters);
  begin match list_field "parameters" "required" parameters with
  | [ Jsont.String (value, _) ] -> equal string ~msg:"required" "count" value
  | required ->
      failf "parameters: expected one required field, got %d"
        (List.length required)
  end;
  let properties = field "parameters" "properties" parameters in
  let count = field "properties" "count" properties in
  equal string ~msg:"integer enum projected to string" "string"
    (string_field "count" "type" count);
  check "scalar properties removed" (not (has_field "properties" count));
  check "scalar required removed" (not (has_field "required" count));
  begin match list_field "count" "enum" count with
  | [ Jsont.String (one, _); Jsont.String (two, _) ] ->
      equal string ~msg:"enum one" "1" one;
      equal string ~msg:"enum two" "2" two
  | enum -> failf "count: expected two enum strings, got %d" (List.length enum)
  end;
  let tags = field "properties" "tags" properties in
  let items = field "tags" "items" tags in
  equal string ~msg:"untyped array item defaults to string" "string"
    (string_field "tags.items" "type" items);
  let maybe = field "properties" "maybe" properties in
  equal string ~msg:"nullable union type" "string"
    (string_field "maybe" "type" maybe);
  equal bool ~msg:"nullable union flag" true
    (bool_field "maybe" "nullable" maybe)

let empty_terminal_candidate_decodes_response () =
  let result, requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event
              (json_object
                 [
                   ( "candidates",
                     Json.list
                       [
                         json_object
                           [
                             ( "content",
                               json_object
                                 [
                                   ("role", Json.string "model");
                                   ("parts", Json.list []);
                                 ] );
                             ("finishReason", Json.string "MAX_TOKENS");
                           ];
                       ] );
                   ("modelVersion", Json.string "gemini-test");
                   ("responseId", Json.string "resp_empty");
                 ]);
          ])
      (fun port -> run_stream port (request ()))
  in
  let events, response = expect_stream_ok "empty terminal candidate" result in
  equal int ~msg:"request count" 1 (List.length requests);
  equal int ~msg:"event count" 0 (List.length events);
  equal string ~msg:"empty response text" "" (Llm.Response.text response);
  equal (list string) ~msg:"empty response texts" []
    (Llm.Response.texts response);
  equal int ~msg:"empty response tool calls" 0
    (List.length (Llm.Response.tool_calls response));
  equal (option string) ~msg:"max tokens stop" (Some "length")
    (Option.map Llm.Response.Stop.label (Llm.Response.stop response));
  equal (option string) ~msg:"provider stop" (Some "MAX_TOKENS")
    (Llm.Response.provider_stop response)

let unknown_finish_reason_is_provider_stop () =
  let result, _requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event
              (json_object
                 [
                   ( "candidates",
                     Json.list
                       [
                         json_object
                           [
                             ( "content",
                               json_object
                                 [
                                   ("role", Json.string "model");
                                   ( "parts",
                                     Json.list
                                       [
                                         json_object
                                           [ ("text", Json.string "blocked") ];
                                       ] );
                                 ] );
                             ("finishReason", Json.string "OTHER");
                           ];
                       ] );
                 ]);
          ])
      (fun port -> run_stream port (request ()))
  in
  let _events, response = expect_stream_ok "unknown finish reason" result in
  equal string ~msg:"response text" "blocked" (Llm.Response.text response);
  equal (option string) ~msg:"normalized stop" (Some "provider_stop")
    (Option.map Llm.Response.Stop.label (Llm.Response.stop response));
  equal (option string) ~msg:"provider stop" (Some "OTHER")
    (Llm.Response.provider_stop response)

let eof_without_finish_reason_is_malformed () =
  let result, _requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event
              (json_object
                 [
                   ( "candidates",
                     Json.list
                       [
                         json_object
                           [
                             ( "content",
                               json_object
                                 [
                                   ("role", Json.string "model");
                                   ( "parts",
                                     Json.list
                                       [
                                         json_object
                                           [ ("text", Json.string "partial") ];
                                       ] );
                                 ] );
                           ];
                       ] );
                 ]);
          ])
      (fun port -> run_stream port (request ()))
  in
  let events, error = expect_stream_error "truncated stream" result in
  equal int ~msg:"text event before failure" 1 (List.length events);
  equal string ~msg:"error kind" "malformed_stream"
    (Llm.Error.label (Llm.Error.kind error));
  equal string ~msg:"error phase" "stream"
    (match Llm.Error.phase error with
    | Llm.Error.Startup -> "startup"
    | Llm.Error.Stream -> "stream")

let completed_stream_decodes_events_and_response () =
  let result, requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event
              (json_object
                 [
                   ( "candidates",
                     Json.list
                       [
                         json_object
                           [
                             ( "content",
                               json_object
                                 [
                                   ("role", Json.string "model");
                                   ( "parts",
                                     Json.list
                                       [
                                         json_object
                                           [
                                             ("text", Json.string "thought");
                                             ("thought", Json.bool true);
                                           ];
                                         json_object
                                           [ ("text", Json.string "hello") ];
                                         json_object
                                           [
                                             ( "functionCall",
                                               json_object
                                                 [
                                                   ("name", Json.string "lookup");
                                                   ( "args",
                                                     json_object
                                                       [
                                                         ( "query",
                                                           Json.string "weather"
                                                         );
                                                       ] );
                                                 ] );
                                           ];
                                       ] );
                                 ] );
                             ("finishReason", Json.string "STOP");
                           ];
                       ] );
                   ( "usageMetadata",
                     json_object
                       [
                         ("promptTokenCount", Json.int 7);
                         ("cachedContentTokenCount", Json.int 2);
                         ("candidatesTokenCount", Json.int 3);
                         ("thoughtsTokenCount", Json.int 1);
                       ] );
                   ("modelVersion", Json.string "gemini-test");
                   ("responseId", Json.string "resp_1");
                 ]);
          ])
      (fun port -> run_stream port (request ()))
  in
  let events, response = expect_stream_ok "completed stream" result in
  equal int ~msg:"request count" 1 (List.length requests);
  let text_deltas, calls, usage_events, reasoning =
    List.fold_left
      (fun (texts, calls, usages, reasoning) -> function
        | Llm.Stream.Event.Text_delta text ->
            (text :: texts, calls, usages, reasoning)
        | Llm.Stream.Event.Tool_call call ->
            (texts, call :: calls, usages, reasoning)
        | Llm.Stream.Event.Usage usage ->
            (texts, calls, usage :: usages, reasoning)
        | Llm.Stream.Event.Reasoning_summary_delta text ->
            (texts, calls, usages, text :: reasoning)
        | Llm.Stream.Event.Tool_input_delta input ->
            ignore input;
            (texts, calls, usages, reasoning))
      ([], [], [], []) events
  in
  equal (list string) ~msg:"text deltas" [ "hello" ] text_deltas;
  equal (list string) ~msg:"reasoning delta" [ "thought" ] reasoning;
  equal int ~msg:"live call count" 1 (List.length calls);
  equal int ~msg:"usage event count" 1 (List.length usage_events);
  equal string ~msg:"response text" "hello" (Llm.Response.text response);
  let call = List.hd (Llm.Response.tool_calls response) in
  equal string ~msg:"tool call id" "tool_resp_1_0" (Llm.Tool.Call.id call);
  equal string ~msg:"tool call name" "lookup" (Llm.Tool.Call.name call);
  equal (option string) ~msg:"response id" (Some "resp_1")
    (Llm.Response.response_id response);
  equal (option string) ~msg:"response model" (Some "gemini-test")
    (Llm.Response.response_model response);
  equal (list string) ~msg:"reasoning retained" [ "thought" ]
    (Llm.Response.reasoning_summary response);
  begin match Llm.Response.usage response with
  | None -> failf "expected usage"
  | Some usage ->
      equal int ~msg:"input" 5 usage.Llm.Usage.input;
      equal int ~msg:"output" 3 usage.Llm.Usage.output;
      equal int ~msg:"reasoning" 1 usage.Llm.Usage.reasoning;
      equal int ~msg:"cache read" 2 usage.Llm.Usage.cache_read
  end

let thought_signatures_round_trip () =
  let signed =
    Llm.Tool.Call.make ~id:"call_signed" ~name:"lookup"
      ~input:(json_object [ ("q", Json.string "a") ])
      ~signature:"sig-1" ()
  in
  let unsigned =
    Llm.Tool.Call.make ~id:"call_unsigned" ~name:"lookup"
      ~input:(json_object [ ("q", Json.string "b") ])
      ()
  in
  let transcript =
    Llm.Transcript.of_list_exn
      [
        Llm.Message.user [ Llm.Content.text "go" ];
        Llm.Message.assistant
          (Llm.Message.Assistant.make
             [
               Llm.Message.Assistant.tool_call signed;
               Llm.Message.Assistant.tool_call unsigned;
             ]);
        Llm.Message.tool_result (Llm.Tool.Result.text signed "one");
        Llm.Message.tool_result (Llm.Tool.Result.text unsigned "two");
      ]
  in
  let result, requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        text_stream "ok")
      (fun port -> run_stream port (request ~transcript ()))
  in
  ignore (expect_stream_ok "stream" result);
  let body = request_body (only_request requests) in
  let contents = list_field "body" "contents" body in
  let assistant_parts = list_field "assistant" "parts" (List.nth contents 1) in
  equal string ~msg:"real signature is round-tripped" "sig-1"
    (string_field "signed call" "thoughtSignature" (List.nth assistant_parts 0));
  check "later signatureless call carries no synthetic signature"
    (not (has_field "thoughtSignature" (List.nth assistant_parts 1)))

let quota_handling_classifies_terminal_and_retryable () =
  (* A 429 naming an exhausted daily/zero quota must fail fast: no retry. *)
  let terminal_body =
    {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaValue":"0"}]}]}}|}
  in
  let result, requests =
    with_google_server
      (fun index request ->
        ignore index;
        ignore request;
        http_response 429 terminal_body)
      (fun port ->
        let config =
          Google.Config.make
            ~base_url:("http://127.0.0.1:" ^ string_of_int port)
            ~max_retries:2 ()
        in
        run_stream ~config port (request ()))
  in
  (match result with
  | Error _ -> ()
  | Ok _ -> failf "terminal quota should fail");
  equal int ~msg:"terminal quota does not retry" 1 (List.length requests);
  (* A 429 with a short RetryInfo delay is retried after honoring it. *)
  let retryable_body =
    {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"0.001s"}]}}|}
  in
  let result, requests =
    with_google_server
      (fun index request ->
        ignore request;
        if index = 0 then http_response 429 retryable_body
        else text_stream "recovered")
      (fun port ->
        let config =
          Google.Config.make
            ~base_url:("http://127.0.0.1:" ^ string_of_int port)
            ~max_retries:2 ()
        in
        run_stream ~config port (request ()))
  in
  let _events, response = expect_stream_ok "retried stream" result in
  equal string ~msg:"recovered text" "recovered" (Llm.Response.text response);
  equal int ~msg:"retryable quota retries once" 2 (List.length requests)

let () =
  run "spice.llm.google"
    [
      test "model, config, and credentials" model_config_and_credentials;
      test "maximal request encoding" maximal_request_encoding;
      test "thought signatures round trip" thought_signatures_round_trip;
      test "quota handling classifies terminal and retryable"
        quota_handling_classifies_terminal_and_retryable;
      test "projected tool schema encoding" projected_tool_schema_encoding;
      test "empty terminal candidate decodes response"
        empty_terminal_candidate_decodes_response;
      test "unknown finish reason is provider stop"
        unknown_finish_reason_is_provider_stop;
      test "EOF without finish reason is malformed"
        eof_without_finish_reason_is_malformed;
      test "completed stream decodes events and response"
        completed_stream_decodes_events_and_response;
    ]
