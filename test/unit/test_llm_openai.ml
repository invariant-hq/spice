(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Llm = Spice_llm
module Openai = Spice_llm_openai
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

let has_field name json = Option.is_some (object_field name json)

let optional_string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some _ | None -> None

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

let equal_stop msg expected response =
  match Llm.Response.stop response with
  | None -> failf "%s: expected stop" msg
  | Some stop ->
      equal string ~msg
        (Llm.Response.Stop.label expected)
        (Llm.Response.Stop.label stop)

let rec waitpid_nointr flags pid =
  match Unix.waitpid flags pid with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr flags pid

let strip_cr line =
  if String.ends_with ~suffix:"\r" line then String.drop_last 1 line else line

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

let with_openai_server respond f =
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
  let requests_path = Filename.temp_file "spice-openai-requests" ".bin" in
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
      let cleanup () =
        Unix.close socket;
        match waitpid_nointr [ Unix.WNOHANG ] pid with
        | 0, _ ->
            (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
            ignore (waitpid_nointr [] pid)
        | _ -> ()
      in
      Fun.protect
        ~finally:(fun () -> Sys.remove requests_path)
        (fun () ->
          let value = Fun.protect ~finally:cleanup (fun () -> f port) in
          (value, read_recorded_requests requests_path))

let sse_event name data =
  "event: " ^ name ^ "\n" ^ "data: " ^ json_string data ^ "\n\n"

let sse_response events =
  http_response ~content_type:"text/event-stream" 200 (String.concat "" events)

let response_json ?(id = "resp_1") ?(status = "completed") ?incomplete_reason
    ?usage output =
  let fields =
    [
      ("id", Json.string id);
      ("status", Json.string status);
      ("model", Json.string "gpt-test");
      ("output", Json.list output);
    ]
  in
  let fields =
    match incomplete_reason with
    | None -> fields
    | Some reason ->
        ("incomplete_details", json_object [ ("reason", Json.string reason) ])
        :: fields
  in
  let fields =
    match usage with None -> fields | Some usage -> ("usage", usage) :: fields
  in
  json_object fields

let message_output text =
  json_object
    [
      ("type", Json.string "message");
      ("role", Json.string "assistant");
      ( "content",
        Json.list
          [
            json_object
              [
                ("type", Json.string "output_text"); ("text", Json.string text);
              ];
          ] );
    ]

let function_call_output ?(arguments = {|{"path":"a.ml"}|}) () =
  json_object
    [
      ("type", Json.string "function_call");
      ("id", Json.string "item_1");
      ("call_id", Json.string "call_1");
      ("name", Json.string "read_file");
      ("arguments", Json.string arguments);
    ]

let reasoning_output () =
  json_object
    [
      ("type", Json.string "reasoning");
      ("id", Json.string "rs_1");
      ("encrypted_content", Json.string "ciphertext");
      ( "summary",
        Json.list
          [
            json_object
              [
                ("type", Json.string "summary_text");
                ("text", Json.string "summary");
              ];
          ] );
    ]

let terminal_event ?name response =
  let name = Option.value name ~default:"response.completed" in
  sse_event name
    (json_object [ ("type", Json.string name); ("response", response) ])

let text_terminal ?name text =
  terminal_event ?name (response_json [ message_output text ])

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", Json.list [ Json.string "path" ]);
      ("additionalProperties", Json.bool false);
    ]

let user_transcript text =
  Llm.Transcript.of_list_exn [ Llm.Message.user_text text ]

let request ?prelude ?tools ?options ?cache_key ?transcript () =
  let transcript = Option.value transcript ~default:(user_transcript "hello") in
  Llm.Request.make_exn ~model:(Openai.model "gpt-test") ?prelude ?tools ?options
    ?cache_key transcript

let run_stream ?(cancelled = fun () -> false) ?config
    ?(credential = Openai.Credential.api_key "sk-test") ?on_event port request =
  let base_url = "http://127.0.0.1:" ^ string_of_int port in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config =
    match config with
    | Some config -> config
    | None -> Openai.Config.make ~base_url ~max_retries:0 ()
  in
  let client = Openai.client ~sw ~env ~config ~credential () in
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

let model_and_config_contracts () =
  let model = Openai.model "gpt-test" in
  check "model provider"
    (Llm.Provider.equal (Llm.Model.provider model) Openai.provider);
  check "model api" (Llm.Model.Api.equal (Llm.Model.api model) Openai.api);
  equal string ~msg:"model id" "gpt-test" (Llm.Model.id model);
  expect_invalid_arg "model id cannot be empty" (fun () ->
      ignore (Openai.model ""));
  let config =
    Openai.Config.make ~base_url:"https://openai.example.test///"
      ~organization:"org" ~project:"proj" ~timeout_s:5. ~max_retries:2 ()
  in
  equal (option string) ~msg:"base_url trimmed"
    (Some "https://openai.example.test")
    (Openai.Config.base_url config);
  equal (option string) ~msg:"organization" (Some "org")
    (Openai.Config.organization config);
  equal (option string) ~msg:"project" (Some "proj")
    (Openai.Config.project config);
  check "timeout" (Openai.Config.timeout_s config = Some 5.);
  equal (option int) ~msg:"max retries" (Some 2)
    (Openai.Config.max_retries config);
  expect_invalid_arg "base_url cannot normalize empty" (fun () ->
      ignore (Openai.Config.make ~base_url:"///" ()));
  expect_invalid_arg "organization cannot contain newline" (fun () ->
      ignore (Openai.Config.make ~organization:"org\n" ()));
  expect_invalid_arg "project cannot contain newline" (fun () ->
      ignore (Openai.Config.make ~project:"proj\r" ()));
  expect_invalid_arg "timeout must be positive" (fun () ->
      ignore (Openai.Config.make ~timeout_s:0. ()));
  expect_invalid_arg "max_retries cannot be negative" (fun () ->
      ignore (Openai.Config.make ~max_retries:(-1) ()))

let credentials_are_explicit_values () =
  ignore (Openai.Credential.api_key "sk-test" : Openai.Credential.t);
  ignore (Openai.Credential.bearer "token" : Openai.Credential.t);
  expect_invalid_arg "api key cannot be empty" (fun () ->
      ignore (Openai.Credential.api_key ""));
  expect_invalid_arg "api key cannot contain newline" (fun () ->
      ignore (Openai.Credential.api_key "sk\nbad"));
  expect_invalid_arg "bearer cannot be empty" (fun () ->
      ignore (Openai.Credential.bearer ""));
  expect_invalid_arg "bearer cannot contain newline" (fun () ->
      ignore (Openai.Credential.bearer "token\rbad"))

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
            Llm.Content.media ~media_type:"image/png" (`Uri "file:///a.png");
            Llm.Content.media ~media_type:"image/jpeg" (`Base64 "abcd");
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
      ~max_output_tokens:128 ~temperature:0.25
      ~reasoning_effort:Llm.Request.Options.Reasoning_effort.High
      ~response_format:
        (Llm.Request.Options.Json_schema
           { name = "answer"; schema; strict = true })
      ()
  in
  let request =
    request ~tools:[ tool ] ~options ~cache_key:"ses-test" ~transcript ()
  in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port -> run_stream port request)
  in
  ignore (expect_stream_ok "stream" result);
  let request = only_request requests in
  equal string ~msg:"method and path" "POST /responses HTTP/1.1"
    request.request_line;
  equal (option string) ~msg:"authorization" (Some "Bearer sk-test")
    (header request "authorization");
  let body = request_body request in
  equal string ~msg:"model" "gpt-test" (string_field "body" "model" body);
  equal bool ~msg:"stream" true (bool_field "body" "stream" body);
  equal bool ~msg:"store" false (bool_field "body" "store" body);
  check "no continuation chaining over HTTP"
    (not (has_field "previous_response_id" body));
  equal string ~msg:"prompt cache key" "ses-test"
    (string_field "body" "prompt_cache_key" body);
  equal int ~msg:"max output tokens" 128
    (int_field "body" "max_output_tokens" body);
  check "temperature omitted with reasoning"
    (not (has_field "temperature" body));
  check "no instructions without a prelude"
    (not (has_field "instructions" body));
  let input = list_field "body" "input" body in
  equal int ~msg:"input item count" 6 (List.length input);
  equal string ~msg:"transcript system rides inline" "system"
    (string_field "system" "role" (List.nth input 0));
  equal string ~msg:"transcript developer rides inline" "developer"
    (string_field "developer" "role" (List.nth input 1));
  let user_content = list_field "user" "content" (List.nth input 2) in
  equal int ~msg:"user content count" 3 (List.length user_content);
  equal string ~msg:"image uri" "file:///a.png"
    (string_field "image uri" "image_url" (List.nth user_content 1));
  equal string ~msg:"image base64" "data:image/jpeg;base64,abcd"
    (string_field "image base64" "image_url" (List.nth user_content 2));
  equal string ~msg:"assistant role" "assistant"
    (string_field "assistant" "role" (List.nth input 3));
  equal string ~msg:"tool call type" "function_call"
    (string_field "tool call" "type" (List.nth input 4));
  equal string ~msg:"tool call arguments" {|{"path":"a.ml"}|}
    (string_field "tool call" "arguments" (List.nth input 4));
  equal string ~msg:"tool result output" "file contents"
    (string_field "tool result" "output" (List.nth input 5));
  let tools = list_field "body" "tools" body in
  equal int ~msg:"tool count" 1 (List.length tools);
  equal string ~msg:"tool name" "read_file"
    (string_field "tool" "name" (List.hd tools));
  equal string ~msg:"tool choice" "read_file"
    (string_field "tool_choice" "name" (field "body" "tool_choice" body));
  equal string ~msg:"reasoning effort" "high"
    (string_field "reasoning" "effort" (field "body" "reasoning" body));
  equal_json "reasoning include"
    (Json.list [ Json.string "reasoning.encrypted_content" ])
    (field "body" "include" body);
  let text = field "body" "text" body in
  let format = field "text" "format" text in
  equal string ~msg:"response format type" "json_schema"
    (string_field "format" "type" format);
  equal bool ~msg:"strict schema" true (bool_field "format" "strict" format)

let structured_tool_result_content_encoding () =
  let call =
    Llm.Tool.Call.make ~id:"call_1" ~name:"inspect"
      ~input:(json_object [ ("path", Json.string "a.png") ])
      ()
  in
  let transcript =
    Llm.Transcript.of_list_exn
      [
        Llm.Message.user_text "inspect this";
        Llm.Message.assistant
          (Llm.Message.Assistant.make [ Llm.Message.Assistant.tool_call call ]);
        Llm.Message.tool_result
          (Llm.Tool.Result.make call
             [
               Llm.Content.text "see";
               Llm.Content.media ~media_type:"image/png" (`Base64 "AA==");
             ]);
      ]
  in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port -> run_stream port (request ~transcript ()))
  in
  ignore (expect_stream_ok "stream" result);
  let body = request_body (only_request requests) in
  let input = list_field "body" "input" body in
  let tool_result = List.nth input 2 in
  let output = list_field "tool result" "output" tool_result in
  equal string ~msg:"tool output text" "see"
    (string_field "tool output text" "text" (List.nth output 0));
  equal string ~msg:"tool output image" "data:image/png;base64,AA=="
    (string_field "tool output image" "image_url" (List.nth output 1))

let headers_and_default_request_encoding () =
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port ->
        let base_url = "http://127.0.0.1:" ^ string_of_int port in
        let config =
          Openai.Config.make ~base_url ~organization:"org_1" ~project:"proj_1"
            ~max_retries:0 ()
        in
        run_stream ~config
          ~credential:(Openai.Credential.bearer "session-token")
          port (request ()))
  in
  ignore (expect_stream_ok "stream" result);
  let request = only_request requests in
  equal (option string) ~msg:"bearer authorization"
    (Some "Bearer session-token")
    (header request "authorization");
  equal (option string) ~msg:"organization header" (Some "org_1")
    (header request "openai-organization");
  equal (option string) ~msg:"project header" (Some "proj_1")
    (header request "openai-project");
  let body = request_body request in
  equal_json "default tool choice" (Json.string "auto")
    (field "body" "tool_choice" body);
  check "tools omitted by default" (not (has_field "tools" body))

let requests_send_full_transcript () =
  let prefix = user_transcript "old context" in
  let transcript =
    match Llm.Transcript.add (Llm.Message.user_text "new message") prefix with
    | Ok transcript -> transcript
    | Error error ->
        failf "extend transcript failed: %a" Llm.Transcript.Error.pp error
  in
  let prelude =
    match
      Llm.Request.Prelude.make
        [
          Llm.Message.system "host system";
          Llm.Message.developer "host developer";
          Llm.Message.user_text "host user context";
        ]
    with
    | Ok prelude -> prelude
    | Error error -> failf "prelude failed: %a" Llm.Request.Error.pp error
  in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port -> run_stream port (request ~prelude ~transcript ()))
  in
  ignore (expect_stream_ok "stream" result);
  let body = request_body (only_request requests) in
  check "previous_response_id is never sent"
    (not (has_field "previous_response_id" body));
  equal string ~msg:"instructions" "host system\n\nhost developer"
    (string_field "body" "instructions" body);
  let input = list_field "body" "input" body in
  equal int ~msg:"full input count" 3 (List.length input);
  equal string ~msg:"prelude user remains input" "host user context"
    (string_field "prelude user content" "text"
       (List.hd (list_field "prelude user" "content" (List.nth input 0))));
  equal string ~msg:"replayed text" "old context"
    (string_field "old content" "text"
       (List.hd (list_field "old user" "content" (List.nth input 1))));
  equal string ~msg:"new text" "new message"
    (string_field "new content" "text"
       (List.hd (list_field "new user" "content" (List.nth input 2))))

let bearer_request_replays_reasoning_with_empty_summary () =
  let reasoning =
    Llm.Message.Assistant.Reasoning.make ~id:"rs_1" ~encrypted:"ciphertext" ()
  in
  let transcript =
    Llm.Transcript.of_list_exn
      [
        Llm.Message.user_text "old context";
        Llm.Message.assistant
          (Llm.Message.Assistant.make
             [
               Llm.Message.Assistant.reasoning_part reasoning;
               Llm.Message.Assistant.text_part "done";
             ]);
        Llm.Message.user_text "new message";
      ]
  in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port ->
        run_stream
          ~credential:(Openai.Credential.bearer "session-token")
          port (request ~transcript ()))
  in
  ignore (expect_stream_ok "bearer reasoning replay" result);
  let body = request_body (only_request requests) in
  let input = list_field "body" "input" body in
  let reasoning = List.nth input 1 in
  equal string ~msg:"reasoning type" "reasoning"
    (string_field "reasoning" "type" reasoning);
  equal string ~msg:"reasoning encrypted" "ciphertext"
    (string_field "reasoning" "encrypted_content" reasoning);
  check "reasoning id omitted for store=false replay"
    (not (has_field "id" reasoning));
  equal int ~msg:"empty summary present" 0
    (List.length (list_field "reasoning" "summary" reasoning))

let bearer_request_omits_reasoning_without_encrypted_content () =
  let reasoning =
    Llm.Message.Assistant.Reasoning.make ~id:"rs_1"
      ~summary:"visible summary without encrypted state" ()
  in
  let transcript =
    Llm.Transcript.of_list_exn
      [
        Llm.Message.user_text "old context";
        Llm.Message.assistant
          (Llm.Message.Assistant.make
             [
               Llm.Message.Assistant.reasoning_part reasoning;
               Llm.Message.Assistant.text_part "done";
             ]);
        Llm.Message.user_text "new message";
      ]
  in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port ->
        run_stream
          ~credential:(Openai.Credential.bearer "session-token")
          port (request ~transcript ()))
  in
  ignore (expect_stream_ok "bearer reasoning omission" result);
  let body = request_body (only_request requests) in
  let input = list_field "body" "input" body in
  check "unreplayable reasoning omitted"
    (List.for_all
       (fun item ->
         not
           (Option.equal String.equal
              (optional_string_field "type" item)
              (Some "reasoning")))
       input)

let reasoning_effort_encoding () =
  let cases =
    let open Llm.Request.Options.Reasoning_effort in
    [ (Disabled, "none"); (High, "high"); (Extra_high, "xhigh") ]
  in
  List.iter
    (fun (effort, expected) ->
      let options = Llm.Request.Options.make ~reasoning_effort:effort () in
      let result, requests =
        with_openai_server
          (fun index request ->
            ignore index;
            ignore request;
            sse_response [ text_terminal "ok" ])
          (fun port -> run_stream port (request ~options ()))
      in
      ignore (expect_stream_ok expected result);
      let body = request_body (only_request requests) in
      equal string
        ~msg:("reasoning effort " ^ expected)
        expected
        (string_field "reasoning" "effort" (field "body" "reasoning" body));
      equal_json
        ("reasoning include " ^ expected)
        (Json.list [ Json.string "reasoning.encrypted_content" ])
        (field "body" "include" body))
    cases

let tool_choice_encoding () =
  let tool =
    Llm.Tool.make ~name:"read_file" ~description:"Read a file."
      ~input_schema:schema ()
  in
  let run options = request ~tools:[ tool ] ~options () in
  let cases =
    [
      ( "auto",
        run (Llm.Request.Options.make ~tool_choice:Llm.Request.Options.Auto ()),
        fun body ->
          equal_json "auto tool choice" (Json.string "auto")
            (field "auto" "tool_choice" body) );
      ( "no tools",
        run
          (Llm.Request.Options.make ~tool_choice:Llm.Request.Options.No_tools ()),
        fun body ->
          equal_json "no tools choice" (Json.string "none")
            (field "no tools" "tool_choice" body) );
      ( "required",
        run
          (Llm.Request.Options.make ~tool_choice:Llm.Request.Options.Required ()),
        fun body ->
          equal_json "required tool choice" (Json.string "required")
            (field "required" "tool_choice" body) );
    ]
  in
  let results, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response [ text_terminal "ok" ])
      (fun port ->
        List.map (fun (_name, request, _check) -> run_stream port request) cases)
  in
  List.iter2
    (fun (name, _request, _check) result ->
      ignore (expect_stream_ok name result))
    cases results;
  List.iter2
    (fun (_name, _request, check) request -> check (request_body request))
    cases requests

let unsupported_requests_do_not_touch_transport () =
  let unsupported_api =
    let model =
      Llm.Model.make ~provider:Openai.provider
        ~api:(Llm.Model.Api.make "unknown")
        ~id:"gpt-test"
    in
    Llm.Request.make_exn ~model (user_transcript "hello")
  in
  let unsupported_media =
    let transcript =
      Llm.Transcript.of_list_exn
        [
          Llm.Message.user
            [
              Llm.Content.media ~media_type:"application/pdf"
                (`Uri "file:///a.pdf");
            ];
        ]
    in
    request ~transcript ()
  in
  let unsupported_tool_result_media =
    let call =
      Llm.Tool.Call.make ~id:"call_1" ~name:"read_file" ~input:schema ()
    in
    let result =
      Llm.Tool.Result.make call
        [
          Llm.Content.media ~media_type:"application/pdf" (`Uri "file:///a.pdf");
        ]
    in
    let transcript =
      Llm.Transcript.of_list_exn
        [
          Llm.Message.assistant
            (Llm.Message.Assistant.make
               [ Llm.Message.Assistant.tool_call call ]);
          Llm.Message.tool_result result;
        ]
    in
    request ~transcript ()
  in
  let unsupported_reasoning_effort =
    let options =
      Llm.Request.Options.make
        ~reasoning_effort:Llm.Request.Options.Reasoning_effort.Max ()
    in
    request ~options ()
  in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        http_response 500 "{}")
      (fun port -> run_stream port unsupported_api)
  in
  let events, error = expect_stream_error "unsupported api" result in
  ignore events;
  equal_error_kind "unsupported api" Llm.Error.Invalid_request error;
  equal int ~msg:"unsupported api request count" 0 (List.length requests);
  List.iter
    (fun (name, kind, request) ->
      let result, requests =
        with_openai_server
          (fun index request ->
            ignore index;
            ignore request;
            http_response 500 "{}")
          (fun port -> run_stream port request)
      in
      let events, error = expect_stream_error name result in
      ignore events;
      equal_error_kind name kind error;
      equal int ~msg:(name ^ " request count") 0 (List.length requests))
    [
      ( "unsupported reasoning effort",
        Llm.Error.Invalid_request,
        unsupported_reasoning_effort );
      ("unsupported media", Llm.Error.Unsupported, unsupported_media);
      ( "unsupported tool result media",
        Llm.Error.Unsupported,
        unsupported_tool_result_media );
    ]

let http_errors_are_classified () =
  let cases =
    [
      (401, Llm.Error.Auth);
      (408, Llm.Error.Timeout);
      (413, Llm.Error.Context_overflow);
      (429, Llm.Error.Rate_limited);
      (500, Llm.Error.Provider);
    ]
  in
  List.iter
    (fun (status, kind) ->
      let body = {|{"error":{"message":"provider said no"}}|} in
      let result, requests =
        with_openai_server
          (fun index request ->
            ignore index;
            ignore request;
            http_response
              ~headers:[ ("openai-request-id", "req_123") ]
              status body)
          (fun port -> run_stream port (request ()))
      in
      let events, error =
        expect_stream_error ("status " ^ string_of_int status) result
      in
      ignore events;
      equal_error_kind ("status " ^ string_of_int status) kind error;
      equal (option int) ~msg:"status retained" (Some status)
        (Llm.Error.status error);
      equal (option string) ~msg:"request id retained" (Some "req_123")
        (Llm.Error.request_id error);
      equal (option string) ~msg:"body redacted"
        (Some
           ("<redacted OpenAI error body: "
           ^ string_of_int (String.length body)
           ^ " bytes>"))
        (Llm.Error.redacted_body error);
      equal int ~msg:"no retries in mapping test" 1 (List.length requests))
    cases

let non_json_http_error_body_is_not_a_log_payload () =
  let body = "secret token sk-test" in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        http_response ~content_type:"text/plain" 500 body)
      (fun port -> run_stream port (request ()))
  in
  equal int ~msg:"request count" 1 (List.length requests);
  let events, error = expect_stream_error "non-json body" result in
  ignore events;
  equal_error_kind "non-json body" Llm.Error.Provider error;
  check "message does not contain raw body"
    (not (String.includes ~affix:"sk-test" (Llm.Error.message error)));
  check "redacted body does not contain raw body"
    (match Llm.Error.redacted_body error with
    | None -> false
    | Some body -> not (String.includes ~affix:"sk-test" body))

let retry_policy () =
  List.iter
    (fun status ->
      let result, requests =
        with_openai_server
          (fun index request ->
            ignore request;
            if index = 0 then
              http_response
                ~headers:[ ("retry-after", "0") ]
                status {|{"error":{"message":"retry"}}|}
            else sse_response [ text_terminal "ok" ])
          (fun port ->
            let base_url = "http://127.0.0.1:" ^ string_of_int port in
            let config = Openai.Config.make ~base_url ~max_retries:1 () in
            run_stream ~config port (request ()))
      in
      ignore (expect_stream_ok ("retry " ^ string_of_int status) result);
      equal int
        ~msg:("retried status " ^ string_of_int status)
        2 (List.length requests))
    [ 408; 409; 429; 500 ];
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        http_response 400 {|{"error":{"message":"bad request"}}|})
      (fun port ->
        let base_url = "http://127.0.0.1:" ^ string_of_int port in
        let config = Openai.Config.make ~base_url ~max_retries:1 () in
        run_stream ~config port (request ()))
  in
  let events, error = expect_stream_error "400 is not retried" result in
  ignore events;
  equal_error_kind "400 kind" Llm.Error.Invalid_request error;
  equal int ~msg:"400 not retried" 1 (List.length requests)

let completed_stream_decodes_events_and_response () =
  let usage =
    json_object
      [
        ("input_tokens", Json.int 7);
        ("input_tokens_details", json_object [ ("cached_tokens", Json.int 2) ]);
        ("output_tokens", Json.int 5);
        ( "output_tokens_details",
          json_object [ ("reasoning_tokens", Json.int 3) ] );
      ]
  in
  let response = response_json ~usage [ message_output "ok" ] in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event "response.output_text.delta"
              (json_object
                 [
                   ("type", Json.string "response.output_text.delta");
                   ("delta", Json.string "ok");
                 ]);
            sse_event "response.reasoning_summary_text.delta"
              (json_object
                 [
                   ("type", Json.string "response.reasoning_summary_text.delta");
                   ("delta", Json.string "thought");
                 ]);
            terminal_event response;
          ])
      (fun port -> run_stream port (request ()))
  in
  let events, response = expect_stream_ok "completed stream" result in
  equal int ~msg:"request count" 1 (List.length requests);
  begin match events with
  | [
   Llm.Stream.Event.Text_delta "ok";
   Llm.Stream.Event.Reasoning_summary_delta "thought";
   Llm.Stream.Event.Usage usage_snapshot;
  ] ->
      equal int ~msg:"live input" 5 usage_snapshot.Llm.Usage.input;
      equal int ~msg:"live output" 2 usage_snapshot.Llm.Usage.output;
      equal int ~msg:"live reasoning" 3 usage_snapshot.Llm.Usage.reasoning;
      equal int ~msg:"live cache read" 2 usage_snapshot.Llm.Usage.cache_read
  | events -> failf "unexpected event count %d" (List.length events)
  end;
  equal (list string) ~msg:"assistant text" [ "ok" ]
    (Llm.Message.Assistant.texts (Llm.Response.assistant response));
  equal_stop "end turn" Llm.Response.Stop.end_turn response;
  equal (option string) ~msg:"response id" (Some "resp_1")
    (Llm.Response.response_id response);
  equal (list string) ~msg:"reasoning summary retained" [ "thought" ]
    (Llm.Response.reasoning_summary response);
  begin match Llm.Response.usage response with
  | None -> failf "expected usage"
  | Some usage ->
      equal int ~msg:"input is disjoint" 5 usage.Llm.Usage.input;
      equal int ~msg:"output is disjoint" 2 usage.Llm.Usage.output;
      equal int ~msg:"reasoning" 3 usage.Llm.Usage.reasoning;
      equal int ~msg:"cache read" 2 usage.Llm.Usage.cache_read
  end

let completed_stream_uses_done_items_when_terminal_output_is_empty () =
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event "response.output_item.done"
              (json_object
                 [
                   ("type", Json.string "response.output_item.done");
                   ("item", message_output "ok");
                 ]);
            terminal_event (response_json []);
          ])
      (fun port -> run_stream port (request ()))
  in
  let _events, response = expect_stream_ok "completed stream fallback" result in
  equal int ~msg:"request count" 1 (List.length requests);
  equal (list string) ~msg:"assistant text" [ "ok" ]
    (Llm.Message.Assistant.texts (Llm.Response.assistant response))

let completed_response_preserves_reasoning_items () =
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            terminal_event
              (response_json [ reasoning_output (); message_output "ok" ]);
          ])
      (fun port -> run_stream port (request ()))
  in
  let _events, response = expect_stream_ok "reasoning response" result in
  equal int ~msg:"request count" 1 (List.length requests);
  let reasonings =
    Llm.Message.Assistant.reasonings (Llm.Response.assistant response)
  in
  equal int ~msg:"reasoning part count" 1 (List.length reasonings);
  let reasoning = List.hd reasonings in
  equal (option string) ~msg:"reasoning id" (Some "rs_1")
    (Llm.Message.Assistant.Reasoning.id reasoning);
  equal (option string) ~msg:"reasoning summary" (Some "summary")
    (Llm.Message.Assistant.Reasoning.summary reasoning);
  equal (option string) ~msg:"reasoning encrypted" (Some "ciphertext")
    (Llm.Message.Assistant.Reasoning.encrypted reasoning)

let streamed_tool_call_is_emitted_once () =
  let terminal = terminal_event (response_json [ function_call_output () ]) in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event "response.output_item.added"
              (json_object
                 [
                   ("type", Json.string "response.output_item.added");
                   ( "item",
                     json_object
                       [
                         ("type", Json.string "function_call");
                         ("id", Json.string "item_1");
                         ("call_id", Json.string "call_1");
                         ("name", Json.string "read_file");
                       ] );
                 ]);
            sse_event "response.function_call_arguments.delta"
              (json_object
                 [
                   ("type", Json.string "response.function_call_arguments.delta");
                   ("item_id", Json.string "item_1");
                   ("delta", Json.string {|{"path"|});
                 ]);
            sse_event "response.function_call_arguments.delta"
              (json_object
                 [
                   ("type", Json.string "response.function_call_arguments.delta");
                   ("item_id", Json.string "item_1");
                   ("delta", Json.string {|:"a.ml"}|});
                 ]);
            sse_event "response.function_call_arguments.done"
              (json_object
                 [
                   ("type", Json.string "response.function_call_arguments.done");
                   ("item_id", Json.string "item_1");
                   ("arguments", Json.string {|{"path":"a.ml"}|});
                 ]);
            sse_event "response.output_item.done"
              (json_object
                 [
                   ("type", Json.string "response.output_item.done");
                   ("item", function_call_output ());
                 ]);
            terminal;
          ])
      (fun port -> run_stream port (request ()))
  in
  equal int ~msg:"request count" 1 (List.length requests);
  let events, response = expect_stream_ok "tool stream" result in
  let input_deltas, calls =
    List.fold_left
      (fun (inputs, calls) -> function
        | Llm.Stream.Event.Tool_input_delta input -> (input :: inputs, calls)
        | Llm.Stream.Event.Tool_call call -> (inputs, call :: calls)
        | Llm.Stream.Event.Text_delta _
        | Llm.Stream.Event.Reasoning_summary_delta _ | Llm.Stream.Event.Usage _
          ->
            (inputs, calls))
      ([], []) events
  in
  equal int ~msg:"input delta count" 2 (List.length input_deltas);
  equal int ~msg:"tool call emitted once" 1 (List.length calls);
  let call = List.hd calls in
  equal string ~msg:"tool call id" "call_1" (Llm.Tool.Call.id call);
  equal string ~msg:"tool call name" "read_file" (Llm.Tool.Call.name call);
  equal_json "tool call input"
    (json_object [ ("path", Json.string "a.ml") ])
    (Llm.Tool.Call.input call);
  equal_stop "tool stop" Llm.Response.Stop.tool_call response;
  equal int ~msg:"durable tool calls" 1
    (List.length
       (Llm.Message.Assistant.tool_calls (Llm.Response.assistant response)))

let terminal_tool_call_is_durable_authority () =
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [ terminal_event (response_json [ function_call_output () ]) ])
      (fun port -> run_stream port (request ()))
  in
  equal int ~msg:"request count" 1 (List.length requests);
  let events, response = expect_stream_ok "terminal tool call" result in
  equal int ~msg:"no live events required" 0 (List.length events);
  let calls =
    Llm.Message.Assistant.tool_calls (Llm.Response.assistant response)
  in
  equal int ~msg:"durable tool call count" 1 (List.length calls);
  let call = List.hd calls in
  equal string ~msg:"call id" "call_1" (Llm.Tool.Call.id call);
  equal string ~msg:"call name" "read_file" (Llm.Tool.Call.name call);
  equal_json "call input"
    (json_object [ ("path", Json.string "a.ml") ])
    (Llm.Tool.Call.input call);
  equal_stop "tool stop" Llm.Response.Stop.tool_call response

let stream_failures_are_classified () =
  let cases =
    [
      ( "eof",
        sse_response
          [
            sse_event "response.output_text.delta"
              (json_object
                 [
                   ("type", Json.string "response.output_text.delta");
                   ("delta", Json.string "x");
                 ]);
          ],
        Llm.Error.Malformed_stream );
      ( "malformed json",
        http_response ~content_type:"text/event-stream" 200
          "event: response.output_text.delta\ndata: {broken\n\n",
        Llm.Error.Decode );
      ( "missing terminal response",
        sse_response
          [
            sse_event "response.completed"
              (json_object [ ("type", Json.string "response.completed") ]);
          ],
        Llm.Error.Decode );
      ( "provider error",
        sse_response
          [
            sse_event "response.failed"
              (json_object
                 [
                   ("type", Json.string "response.failed");
                   ("error", json_object [ ("message", Json.string "failed") ]);
                 ]);
          ],
        Llm.Error.Provider );
      ( "nested provider error",
        sse_response
          [
            sse_event "response.failed"
              (json_object
                 [
                   ("type", Json.string "response.failed");
                   ( "response",
                     json_object
                       [
                         ( "error",
                           json_object
                             [
                               ("code", Json.string "context_length_exceeded");
                               ("message", Json.string "too long");
                             ] );
                       ] );
                 ]);
          ],
        Llm.Error.Context_overflow );
      ( "empty output",
        sse_response [ terminal_event (response_json []) ],
        Llm.Error.Decode );
      ( "invalid streamed tool input",
        sse_response
          [
            sse_event "response.output_item.added"
              (json_object
                 [
                   ("type", Json.string "response.output_item.added");
                   ( "item",
                     json_object
                       [
                         ("type", Json.string "function_call");
                         ("id", Json.string "item_1");
                         ("call_id", Json.string "call_1");
                         ("name", Json.string "read_file");
                       ] );
                 ]);
            sse_event "response.function_call_arguments.done"
              (json_object
                 [
                   ("type", Json.string "response.function_call_arguments.done");
                   ("item_id", Json.string "item_1");
                   ("arguments", Json.string "{broken");
                 ]);
          ],
        Llm.Error.Decode );
      ( "invalid terminal tool input",
        sse_response
          [
            terminal_event
              (response_json [ function_call_output ~arguments:"{broken" () ]);
          ],
        Llm.Error.Decode );
    ]
  in
  List.iter
    (fun (name, response, kind) ->
      let result, requests =
        with_openai_server
          (fun index request ->
            ignore index;
            ignore request;
            response)
          (fun port -> run_stream port (request ()))
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

let response_stop_reasons_are_normalized () =
  let cases =
    [
      ("length", "max_output_tokens", Llm.Response.Stop.length);
      ("content filter", "content_filter", Llm.Response.Stop.content_filter);
      ("other", "safety_stop", Llm.Response.Stop.other "safety_stop");
    ]
  in
  List.iter
    (fun (name, reason, stop) ->
      let result, requests =
        with_openai_server
          (fun index request ->
            ignore index;
            ignore request;
            sse_response
              [
                terminal_event ~name:"response.incomplete"
                  (response_json ~status:"incomplete" ~incomplete_reason:reason
                     [ message_output "partial" ]);
              ])
          (fun port -> run_stream port (request ()))
      in
      equal int ~msg:(name ^ " request count") 1 (List.length requests);
      let events, response = expect_stream_ok name result in
      ignore events;
      equal_stop name stop response)
    cases

let cancellation_is_reported_without_leaking_requests () =
  let cancelled = ref true in
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        http_response 500 "{}")
      (fun port ->
        run_stream ~cancelled:(fun () -> !cancelled) port (request ()))
  in
  let events, error = expect_stream_error "startup cancellation" result in
  ignore events;
  equal_error_kind "startup cancellation" Llm.Error.Cancelled error;
  equal int ~msg:"no request when already cancelled" 0 (List.length requests);
  cancelled := false;
  let result, requests =
    with_openai_server
      (fun index request ->
        ignore index;
        ignore request;
        sse_response
          [
            sse_event "response.output_text.delta"
              (json_object
                 [
                   ("type", Json.string "response.output_text.delta");
                   ("delta", Json.string "first");
                 ]);
            text_terminal "late";
          ])
      (fun port ->
        run_stream
          ~cancelled:(fun () -> !cancelled)
          ~on_event:(fun event ->
            match event with
            | Llm.Stream.Event.Text_delta "first" -> cancelled := true
            | Llm.Stream.Event.Text_delta _
            | Llm.Stream.Event.Reasoning_summary_delta _
            | Llm.Stream.Event.Tool_input_delta _ | Llm.Stream.Event.Tool_call _
            | Llm.Stream.Event.Usage _ ->
                ())
          port (request ()))
  in
  equal int ~msg:"request before stream cancellation" 1 (List.length requests);
  let events, error = expect_stream_error "stream cancellation" result in
  equal int ~msg:"one event before cancellation" 1 (List.length events);
  equal_error_kind "stream cancellation" Llm.Error.Cancelled error;
  equal string ~msg:"stream cancellation phase" "stream"
    (match Llm.Error.phase error with
    | Llm.Error.Startup -> "startup"
    | Llm.Error.Stream -> "stream")

let () =
  run "spice.llm.openai"
    [
      test "model and config contracts" model_and_config_contracts;
      test "credentials are explicit values" credentials_are_explicit_values;
      test "maximal request encoding" maximal_request_encoding;
      test "structured tool result content encoding"
        structured_tool_result_content_encoding;
      test "headers and default request encoding"
        headers_and_default_request_encoding;
      test "requests send full transcript" requests_send_full_transcript;
      test "bearer request replays reasoning with empty summary"
        bearer_request_replays_reasoning_with_empty_summary;
      test "bearer request omits reasoning without encrypted content"
        bearer_request_omits_reasoning_without_encrypted_content;
      test "reasoning effort encoding" reasoning_effort_encoding;
      test "tool choice encoding" tool_choice_encoding;
      test "unsupported requests do not touch transport"
        unsupported_requests_do_not_touch_transport;
      test "HTTP errors are classified" http_errors_are_classified;
      test "non-json HTTP error body is not a log payload"
        non_json_http_error_body_is_not_a_log_payload;
      test "retry policy" retry_policy;
      test "completed stream decodes events and response"
        completed_stream_decodes_events_and_response;
      test "completed stream falls back to done items"
        completed_stream_uses_done_items_when_terminal_output_is_empty;
      test "completed response preserves reasoning items"
        completed_response_preserves_reasoning_items;
      test "streamed tool call is emitted once"
        streamed_tool_call_is_emitted_once;
      test "terminal tool call is durable authority"
        terminal_tool_call_is_durable_authority;
      test "stream failures are classified" stream_failures_are_classified;
      test "response stop reasons are normalized"
        response_stop_reasons_are_normalized;
      test "cancellation is reported without leaking requests"
        cancellation_is_reported_without_leaking_requests;
    ]
