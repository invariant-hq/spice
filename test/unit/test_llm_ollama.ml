(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Llm = Spice_llm
module Ollama = Spice_llm_ollama
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

let equal_json msg expected actual = check msg (Json.equal expected actual)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let field msg name json =
  match object_field name json with
  | Some value -> value
  | None -> failf "%s: missing JSON field %s" msg name

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

let int_field msg name json =
  match field msg name json with
  | Jsont.Number (value, _) when Float.is_integer value -> int_of_float value
  | value ->
      failf "%s: expected int field %s, got %s" msg name (json_string value)

let number_field msg name json =
  match field msg name json with
  | Jsont.Number (value, _) -> value
  | value ->
      failf "%s: expected number field %s, got %s" msg name (json_string value)

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

let equal_error_kind msg kind error =
  equal string ~msg (Llm.Error.label kind)
    (Llm.Error.label (Llm.Error.kind error))

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

let with_ollama_server respond f =
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
  let requests_path = Filename.temp_file "spice-ollama-requests" ".bin" in
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
      let cleanup () =
        match waitpid_nointr [ Unix.WNOHANG ] pid with
        | 0, _ ->
            begin match Unix.kill pid Sys.sigterm with
            | () -> ()
            | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()
            end;
            ignore (waitpid_nointr [] pid)
        | _ -> ()
      in
      Fun.protect
        ~finally:(fun () -> Sys.remove requests_path)
        (fun () ->
          let value = Fun.protect ~finally:cleanup (fun () -> f port) in
          (value, read_recorded_requests requests_path))

let sse_response body = http_response ~content_type:"text/event-stream" 200 body

let sse_events chunks =
  String.concat ""
    (List.map (fun chunk -> "data: " ^ json_string chunk ^ "\n\n") chunks)
  ^ "data: [DONE]\n\n"

let delta_chunk ?id ?model ?finish_reason ?usage delta =
  let choice =
    [ ("delta", json_object delta) ]
    @ Option.fold ~none:[]
        ~some:(fun reason -> [ ("finish_reason", Json.string reason) ])
        finish_reason
  in
  json_object
    (Option.fold ~none:[] ~some:(fun id -> [ ("id", Json.string id) ]) id
    @ Option.fold ~none:[]
        ~some:(fun model -> [ ("model", Json.string model) ])
        model
    @ [ ("choices", Json.list [ json_object choice ]) ]
    @ Option.fold ~none:[] ~some:(fun usage -> [ ("usage", usage) ]) usage)

let text_stream text =
  sse_response
    (sse_events
       [ delta_chunk ~finish_reason:"stop" [ ("content", Json.string text) ] ])

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", Json.list [ Json.string "path" ]);
    ]

let read_file_tool =
  Llm.Tool.make ~name:"read_file" ~description:"Read a file."
    ~input_schema:schema ()

let user_transcript text =
  Llm.Transcript.of_list_exn [ Llm.Message.user_text text ]

let request ?tools ?options ?transcript () =
  let transcript = Option.value transcript ~default:(user_transcript "hello") in
  Llm.Request.make_exn
    ~model:(Ollama.model "qwen2.5-coder:7b")
    ?tools ?options transcript

let run_stream ?(cancelled = fun () -> false) ?credential ?on_event port request
    =
  let config =
    Ollama.Config.make ~base_url:("http://127.0.0.1:" ^ string_of_int port) ()
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Ollama.client ~sw ~env ~config ?credential () in
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
  let model = Ollama.model "qwen2.5-coder:7b" in
  check "model provider"
    (Llm.Provider.equal (Llm.Model.provider model) Ollama.provider);
  check "model api" (Llm.Model.Api.equal (Llm.Model.api model) Ollama.api);
  equal string ~msg:"model id" "qwen2.5-coder:7b" (Llm.Model.id model);
  expect_invalid_arg "model id cannot be empty" (fun () ->
      ignore (Ollama.model ""));
  ignore (Ollama.Config.make () : Ollama.Config.t);
  expect_invalid_arg "base_url cannot be empty" (fun () ->
      ignore (Ollama.Config.make ~base_url:"" ()));
  ignore (Ollama.Credential.api_key "ollama-key" : Ollama.Credential.t);
  ignore (Ollama.Credential.bearer "session-token" : Ollama.Credential.t);
  expect_invalid_arg "api key cannot be empty" (fun () ->
      ignore (Ollama.Credential.api_key ""));
  expect_invalid_arg "bearer cannot be empty" (fun () ->
      ignore (Ollama.Credential.bearer ""))

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
        Llm.Message.user [ Llm.Content.text "inspect this" ];
        Llm.Message.assistant
          (Llm.Message.Assistant.make
             [
               Llm.Message.Assistant.text_part "checking";
               Llm.Message.Assistant.tool_call call;
             ]);
        Llm.Message.tool_result (Llm.Tool.Result.text call "file contents");
      ]
  in
  let response_format =
    Llm.Request.Options.Json_schema { name = "answer"; schema; strict = true }
  in
  let options =
    Llm.Request.Options.make ~tool_choice:(Llm.Request.Options.Tool "read_file")
      ~response_format ~max_output_tokens:2048 ~temperature:0.25
      ~reasoning_effort:Llm.Request.Options.Reasoning_effort.High ()
  in
  let result, requests =
    with_ollama_server
      (fun index request ->
        ignore index;
        ignore request;
        text_stream "ok")
      (fun port ->
        run_stream
          ~credential:(Ollama.Credential.bearer "session-token")
          port
          (request ~tools:[ read_file_tool ] ~options ~transcript ()))
  in
  ignore (expect_stream_ok "stream" result);
  let recorded = only_request requests in
  equal string ~msg:"method and path" "POST /v1/chat/completions HTTP/1.1"
    recorded.request_line;
  equal (option string) ~msg:"authorization" (Some "Bearer session-token")
    (header recorded "authorization");
  let body = request_body recorded in
  equal string ~msg:"model" "qwen2.5-coder:7b"
    (string_field "body" "model" body);
  equal bool ~msg:"stream" true (bool_field "body" "stream" body);
  equal int ~msg:"max tokens" 2048 (int_field "body" "max_tokens" body);
  check "temperature" (number_field "body" "temperature" body = 0.25);
  equal string ~msg:"reasoning effort" "high"
    (string_field "body" "reasoning_effort" body);
  let stream_options = field "body" "stream_options" body in
  equal bool ~msg:"include usage" true
    (bool_field "stream options" "include_usage" stream_options);
  let messages = list_field "body" "messages" body in
  equal int ~msg:"message count" 5 (List.length messages);
  equal string ~msg:"system role" "system"
    (string_field "system" "role" (List.nth messages 0));
  equal string ~msg:"developer projected to system" "system"
    (string_field "developer" "role" (List.nth messages 1));
  equal string ~msg:"user role" "user"
    (string_field "user" "role" (List.nth messages 2));
  let assistant = List.nth messages 3 in
  equal string ~msg:"assistant role" "assistant"
    (string_field "assistant" "role" assistant);
  equal string ~msg:"assistant content" "checking"
    (string_field "assistant" "content" assistant);
  let tool_call = List.hd (list_field "assistant" "tool_calls" assistant) in
  equal string ~msg:"tool call id" "call_1"
    (string_field "tool call" "id" tool_call);
  let fn = field "tool call" "function" tool_call in
  equal string ~msg:"tool call name" "read_file"
    (string_field "tool call" "name" fn);
  equal string ~msg:"tool call arguments" {|{"path":"a.ml"}|}
    (string_field "tool call" "arguments" fn);
  let tool_result = List.nth messages 4 in
  equal string ~msg:"tool result role" "tool"
    (string_field "tool result" "role" tool_result);
  equal string ~msg:"tool result id" "call_1"
    (string_field "tool result" "tool_call_id" tool_result);
  equal string ~msg:"tool result content" "file contents"
    (string_field "tool result" "content" tool_result);
  let tool = List.hd (list_field "body" "tools" body) in
  equal string ~msg:"tool type" "function" (string_field "tool" "type" tool);
  let tool_choice = field "body" "tool_choice" body in
  equal string ~msg:"tool choice type" "function"
    (string_field "tool choice" "type" tool_choice);
  let response_format = field "body" "response_format" body in
  equal string ~msg:"response format type" "json_schema"
    (string_field "response format" "type" response_format);
  let json_schema = field "response format" "json_schema" response_format in
  equal string ~msg:"schema name" "answer"
    (string_field "json schema" "name" json_schema);
  equal_json "schema payload" schema (field "json schema" "schema" json_schema)

let unsupported_requests_do_not_touch_transport () =
  let unsupported =
    [
      ( "media",
        request
          ~transcript:
            (Llm.Transcript.of_list_exn
               [
                 Llm.Message.user
                   [
                     Llm.Content.text "see";
                     Llm.Content.media ~media_type:"image/png" (`Base64 "abcd");
                   ];
               ])
          () );
      ( "reasoning max",
        let options =
          Llm.Request.Options.make
            ~reasoning_effort:Llm.Request.Options.Reasoning_effort.Max ()
        in
        request ~options () );
    ]
  in
  List.iter
    (fun (name, request) ->
      let result, requests =
        with_ollama_server
          (fun _index _request -> failf "%s: transport should not be used" name)
          (fun port -> run_stream port request)
      in
      let events, error = expect_stream_error name result in
      equal int ~msg:(name ^ " events") 0 (List.length events);
      equal_error_kind name Llm.Error.Unsupported error;
      equal int ~msg:(name ^ " requests") 0 (List.length requests))
    unsupported

let completed_stream_decodes_events_and_response () =
  let result, requests =
    with_ollama_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          (sse_events
             [
               delta_chunk ~id:"chatcmpl-1" ~model:"qwen2.5-coder:7b"
                 [ ("content", Json.string "Hel") ];
               delta_chunk [ ("content", Json.string "lo") ];
               delta_chunk [ ("reasoning_content", Json.string "thinking") ];
               delta_chunk
                 [
                   ( "tool_calls",
                     Json.list
                       [
                         json_object
                           [
                             ("index", Json.int 0);
                             ("id", Json.string "call_1");
                             ( "function",
                               json_object
                                 [
                                   ("name", Json.string "read_file");
                                   ("arguments", Json.string {|{"path":|});
                                 ] );
                           ];
                       ] );
                 ];
               delta_chunk
                 [
                   ( "tool_calls",
                     Json.list
                       [
                         json_object
                           [
                             ("index", Json.int 0);
                             ( "function",
                               json_object
                                 [ ("arguments", Json.string {|"a.ml"}|}) ] );
                           ];
                       ] );
                 ];
               delta_chunk ~finish_reason:"tool_calls" [];
               json_object
                 [
                   ("choices", Json.list []);
                   ( "usage",
                     json_object
                       [
                         ("prompt_tokens", Json.int 10);
                         ( "prompt_tokens_details",
                           json_object [ ("cached_tokens", Json.int 3) ] );
                         ("completion_tokens", Json.int 8);
                         ( "completion_tokens_details",
                           json_object [ ("reasoning_tokens", Json.int 2) ] );
                       ] );
                 ];
             ]))
      (fun port -> run_stream port (request ~tools:[ read_file_tool ] ()))
  in
  let events, response = expect_stream_ok "completed stream" result in
  equal int ~msg:"request count" 1 (List.length requests);
  let text_deltas, input_deltas, calls, usage_events, reasoning =
    List.fold_left
      (fun (texts, inputs, calls, usages, reasoning) -> function
        | Llm.Stream.Event.Text_delta text ->
            (text :: texts, inputs, calls, usages, reasoning)
        | Llm.Stream.Event.Tool_input_delta input ->
            (texts, input :: inputs, calls, usages, reasoning)
        | Llm.Stream.Event.Tool_call call ->
            (texts, inputs, call :: calls, usages, reasoning)
        | Llm.Stream.Event.Usage usage ->
            (texts, inputs, calls, usage :: usages, reasoning)
        | Llm.Stream.Event.Reasoning_summary_delta text ->
            (texts, inputs, calls, usages, text :: reasoning))
      ([], [], [], [], []) events
  in
  equal (list string) ~msg:"text deltas" [ "lo"; "Hel" ] text_deltas;
  equal int ~msg:"tool input deltas" 2 (List.length input_deltas);
  equal int ~msg:"live tool calls" 1 (List.length calls);
  equal int ~msg:"usage events" 1 (List.length usage_events);
  equal (list string) ~msg:"reasoning delta" [ "thinking" ] reasoning;
  equal string ~msg:"response text" "Hello" (Llm.Response.text response);
  let reasonings =
    Llm.Message.Assistant.reasonings (Llm.Response.assistant response)
  in
  begin match reasonings with
  | [ reasoning ] ->
      equal (option string) ~msg:"durable reasoning text" (Some "thinking")
        (Llm.Message.Assistant.Reasoning.text reasoning)
  | reasonings ->
      failf "expected one durable reasoning part, got %d"
        (List.length reasonings)
  end;
  begin match Llm.Response.tool_calls response with
  | [ call ] ->
      equal string ~msg:"call id" "call_1" (Llm.Tool.Call.id call);
      equal string ~msg:"call name" "read_file" (Llm.Tool.Call.name call);
      equal_json "call input"
        (json_object [ ("path", Json.string "a.ml") ])
        (Llm.Tool.Call.input call)
  | calls -> failf "expected one call, got %d" (List.length calls)
  end;
  equal (option string) ~msg:"response id" (Some "chatcmpl-1")
    (Llm.Response.response_id response);
  equal (option string) ~msg:"response model" (Some "qwen2.5-coder:7b")
    (Llm.Response.response_model response);
  equal (option string) ~msg:"stop" (Some "tool_call")
    (Option.map Llm.Response.Stop.label (Llm.Response.stop response));
  equal (option string) ~msg:"provider stop" (Some "tool_calls")
    (Llm.Response.provider_stop response);
  begin match Llm.Response.usage response with
  | None -> failf "expected usage"
  | Some usage ->
      equal int ~msg:"input" 7 usage.Llm.Usage.input;
      equal int ~msg:"cache read" 3 usage.Llm.Usage.cache_read;
      equal int ~msg:"output" 6 usage.Llm.Usage.output;
      equal int ~msg:"reasoning" 2 usage.Llm.Usage.reasoning
  end

let http_errors_are_classified () =
  let cases =
    [
      (400, Llm.Error.Invalid_request);
      (413, Llm.Error.Context_overflow);
      (500, Llm.Error.Provider);
    ]
  in
  List.iter
    (fun (status, kind) ->
      let result, requests =
        with_ollama_server
          (fun index request ->
            ignore index;
            ignore request;
            http_response status
              {|{"error":{"message":"ollama failure from daemon"}}|})
          (fun port -> run_stream port (request ()))
      in
      equal int
        ~msg:("status " ^ string_of_int status ^ " request count")
        1 (List.length requests);
      let events, error =
        expect_stream_error ("status " ^ string_of_int status) result
      in
      equal int ~msg:"no startup events" 0 (List.length events);
      equal_error_kind ("status " ^ string_of_int status) kind error;
      equal (option int) ~msg:"status retained" (Some status)
        (Llm.Error.status error);
      equal string ~msg:"daemon message" "ollama failure from daemon"
        (Llm.Error.message error))
    cases

let stream_failures_are_classified () =
  let cases =
    [
      ("malformed json", sse_response "data: {broken\n\n", Llm.Error.Decode);
      ( "eof without done",
        sse_response
          ("data: "
          ^ json_string (delta_chunk [ ("content", Json.string "partial") ])
          ^ "\n\n"),
        Llm.Error.Malformed_stream );
      ( "tool input missing name",
        sse_response
          (sse_events
             [
               delta_chunk
                 [
                   ( "tool_calls",
                     Json.list
                       [
                         json_object
                           [
                             ("index", Json.int 0);
                             ("id", Json.string "call_1");
                             ( "function",
                               json_object
                                 [ ("arguments", Json.string {|{"x":1}|}) ] );
                           ];
                       ] );
                 ];
               delta_chunk ~finish_reason:"tool_calls" [];
             ]),
        Llm.Error.Decode );
      ( "invalid tool input",
        sse_response
          (sse_events
             [
               delta_chunk
                 [
                   ( "tool_calls",
                     Json.list
                       [
                         json_object
                           [
                             ("index", Json.int 0);
                             ("id", Json.string "call_1");
                             ( "function",
                               json_object
                                 [
                                   ("name", Json.string "read_file");
                                   ("arguments", Json.string "{broken");
                                 ] );
                           ];
                       ] );
                 ];
               delta_chunk ~finish_reason:"tool_calls" [];
             ]),
        Llm.Error.Decode );
    ]
  in
  List.iter
    (fun (name, response, kind) ->
      let result, requests =
        with_ollama_server
          (fun index request ->
            ignore index;
            ignore request;
            response)
          (fun port -> run_stream port (request ~tools:[ read_file_tool ] ()))
      in
      equal int ~msg:(name ^ " request count") 1 (List.length requests);
      let events, error = expect_stream_error name result in
      ignore events;
      equal_error_kind name kind error;
      equal string ~msg:(name ^ " phase") "stream"
        (match Llm.Error.phase error with
        | Llm.Error.Startup -> "startup"
        | Llm.Error.Stream -> "stream"))
    cases

let startup_cancellation_does_not_touch_transport () =
  let result, requests =
    with_ollama_server
      (fun _index _request -> failf "transport should not be used")
      (fun port -> run_stream ~cancelled:(fun () -> true) port (request ()))
  in
  let events, error = expect_stream_error "startup cancellation" result in
  equal int ~msg:"events" 0 (List.length events);
  equal_error_kind "cancelled" Llm.Error.Cancelled error;
  equal int ~msg:"requests" 0 (List.length requests)

let () =
  run "spice.llm.ollama"
    [
      test "model, config, and credentials" model_config_and_credentials;
      test "maximal request encoding" maximal_request_encoding;
      test "unsupported requests do not touch transport"
        unsupported_requests_do_not_touch_transport;
      test "completed stream decodes events and response"
        completed_stream_decodes_events_and_response;
      test "HTTP errors are classified" http_errors_are_classified;
      test "stream failures are classified" stream_failures_are_classified;
      test "startup cancellation does not touch transport"
        startup_cancellation_does_not_touch_transport;
    ]
