(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Llm = Spice_llm
module Client = Llm.Client
module Content = Llm.Content
module Error = Llm.Error
module Json = Jsont.Json
module Message = Llm.Message
module Model = Llm.Model
module Provider = Llm.Provider
module Request = Llm.Request
module Response = Llm.Response
module Stop = Llm.Response.Stop
module Stream = Llm.Stream
module Tool = Llm.Tool
module Transcript = Llm.Transcript
module Usage = Llm.Usage

exception Callback_failure

let opaque name =
  testable ~pp:(fun ppf _ -> Format.pp_print_string ppf name) ~equal:( = ) ()

let provider_value = testable ~pp:Provider.pp ~equal:Provider.equal ()
let api_value = testable ~pp:Model.Api.pp ~equal:Model.Api.equal ()
let model_value = testable ~pp:Model.pp ~equal:Model.equal ()
let stop_value = testable ~pp:Stop.pp ~equal:Stop.equal ()
let usage_value = testable ~pp:Usage.pp ~equal:Usage.equal ()
let error_value = testable ~pp:Error.pp ~equal:Error.equal ()
let transcript_error = testable ~pp:Transcript.Error.pp ~equal:( = ) ()
let request_error = testable ~pp:Request.Error.pp ~equal:( = ) ()

let expect_error msg result check =
  match result with
  | Ok value ->
      ignore value;
      failf "%s: expected Error" msg
  | Error error -> check error

let expect_decode_error msg codec json =
  match Json.decode codec json with
  | Ok value ->
      ignore value;
      failf "%s: expected decode error" msg
  | Error message -> ignore message

let roundtrip msg testable codec value =
  equal testable ~msg value (decode codec (encode codec value))

let equal_json msg expected actual = is_true ~msg (Json.equal expected actual)

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", json_array [ Json.string "path" ]);
      ("additionalProperties", Json.bool false);
    ]

let empty_object = Json.object' []
let openai = Provider.make "openai"
let anthropic = Provider.make "anthropic"
let responses = Model.Api.make "responses"

let model ?(provider = openai) ?(api = responses) id =
  Model.make ~provider ~api ~id

let gpt = model "gpt-5"

let tool ?(name = "read_file") () =
  Tool.make ~name ~description:"Read a file." ~input_schema:schema ()

let call ?(id = "call_1") ?(name = "read_file") () =
  Tool.Call.make ~id ~name
    ~input:(json_object [ ("path", Json.string "a.ml") ])
    ()

let assistant_with_calls calls =
  Message.Assistant.make
    (Message.Assistant.text_part "I will use a tool."
    :: List.map Message.Assistant.tool_call calls)

let ready_transcript () =
  Transcript.of_list_exn
    [ Message.developer "You are Spice."; Message.user_text "Refactor a.ml." ]

let response ?(assistant = Message.Assistant.text "Done.") () =
  Response.make ~model:gpt assistant

let provider_contracts () =
  equal string ~msg:"provider id" "openai" (Provider.id openai);
  roundtrip "provider JSON" provider_value Provider.jsont openai;
  List.iter
    (fun id ->
      let provider = Provider.make id in
      equal string ~msg:("valid provider " ^ id) id (Provider.id provider))
    [ "a"; "openai"; "x-ai"; "a1" ];
  List.iter
    (fun id ->
      expect_invalid_arg
        ("invalid provider " ^ String.escaped id)
        (fun () -> Provider.make id))
    [ ""; "OpenAI"; "-openai"; "open_ai"; "open.ai" ]

let model_contracts () =
  let chat = Model.Api.make "chat.completions" in
  equal string ~msg:"api id" "chat.completions" (Model.Api.id chat);
  equal string ~msg:"model id" "gpt-5" (Model.id gpt);
  equal provider_value ~msg:"model provider" openai (Model.provider gpt);
  equal api_value ~msg:"model api" responses (Model.api gpt);
  roundtrip "api JSON" api_value Model.Api.jsont chat;
  roundtrip "model JSON" model_value Model.jsont gpt;
  List.iter
    (fun id ->
      expect_invalid_arg
        ("invalid api " ^ String.escaped id)
        (fun () -> Model.Api.make id))
    [
      "";
      "Responses";
      ".responses";
      "responses.";
      "chat..completions";
      "chat_completions";
    ];
  expect_invalid_arg "empty model id" (fun () -> model "")

let content_contracts () =
  let text = Content.text "hello" in
  let media =
    Content.media ~media_type:"image/png" (`Uri "file:///tmp/a.png")
  in
  begin match text with
  | Content.Text value -> equal string ~msg:"text content" "hello" value
  | Content.Media _ -> failf "unexpected media"
  end;
  begin match media with
  | Content.Media { media_type; source = `Uri uri } ->
      equal string ~msg:"media type" "image/png" media_type;
      equal string ~msg:"media uri" "file:///tmp/a.png" uri
  | Content.Text _ | Content.Media { source = `Base64 _; _ } ->
      failf "unexpected content"
  end;
  roundtrip "text content JSON" (opaque "content") Content.jsont text;
  roundtrip "media content JSON" (opaque "content") Content.jsont media;
  expect_invalid_arg "empty text content" (fun () -> Content.text "");
  expect_invalid_arg "empty media type" (fun () ->
      Content.media ~media_type:"" (`Uri "x"));
  expect_invalid_arg "empty media uri" (fun () ->
      Content.media ~media_type:"image/png" (`Uri ""));
  expect_invalid_arg "empty media base64" (fun () ->
      Content.media ~media_type:"image/png" (`Base64 ""))

let tool_contracts () =
  begin match Tool.no_input_schema with
  | Jsont.Object _ -> ()
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      failf "no-input schema must be an object"
  end;
  let declaration = tool () in
  equal string ~msg:"tool name" "read_file" (Tool.name declaration);
  equal (option string) ~msg:"tool description" (Some "Read a file.")
    (Tool.description declaration);
  is_true ~msg:"schema retained"
    (Json.equal schema (Tool.input_schema declaration));
  roundtrip "tool JSON" (opaque "tool") Tool.jsont declaration;
  let valid_names =
    [ "a"; "_private"; "read_file"; "read-file"; "read2"; String.make 64 'a' ]
  in
  List.iter
    (fun name ->
      equal string ~msg:("valid tool " ^ name) name (Tool.name (tool ~name ())))
    valid_names;
  List.iter
    (fun name ->
      expect_invalid_arg
        ("invalid tool " ^ String.escaped name)
        (fun () -> tool ~name ()))
    [ ""; "2read"; "-read"; "read.file"; "read file"; String.make 65 'a' ];
  expect_invalid_arg "empty description" (fun () ->
      Tool.make ~name:"bad" ~description:"" ~input_schema:schema ());
  expect_invalid_arg "non-object schema" (fun () ->
      Tool.make ~name:"bad" ~input_schema:(Json.string "schema") ());
  let call = call () in
  equal string ~msg:"call id" "call_1" (Tool.Call.id call);
  equal string ~msg:"call name" "read_file" (Tool.Call.name call);
  roundtrip "tool call JSON" (opaque "tool call") Tool.Call.jsont call;
  expect_invalid_arg "empty call id" (fun () ->
      Tool.Call.make ~id:"" ~name:"read_file" ~input:empty_object ());
  expect_invalid_arg "bad call name" (fun () ->
      Tool.Call.make ~id:"id" ~name:"bad name" ~input:empty_object ());
  let empty_result = Tool.Result.empty call in
  equal (list string) ~msg:"empty result has no texts" []
    (Tool.Result.texts empty_result);
  equal bool ~msg:"empty result not error" false
    (Tool.Result.is_error empty_result);
  let text_result = Tool.Result.text ~error:true call "contents" in
  equal (list string) ~msg:"text result texts" [ "contents" ]
    (Tool.Result.texts text_result);
  equal bool ~msg:"text result error" true (Tool.Result.is_error text_result);
  roundtrip "tool result JSON" (opaque "tool result") Tool.Result.jsont
    text_result;
  expect_invalid_arg "empty result text" (fun () -> Tool.Result.text call "");
  expect_invalid_arg "raw result empty call id" (fun () ->
      Tool.Result.make_raw ~call_id:"" ~name:"read_file" []);
  expect_invalid_arg "raw result bad name" (fun () ->
      Tool.Result.make_raw ~call_id:"call" ~name:"bad name" [])

let usage_contracts () =
  let a =
    Usage.make ~input:1 ~output:2 ~reasoning:3 ~cache_read:4 ~cache_write:5 ()
  in
  let b =
    Usage.make ~input:10 ~output:20 ~reasoning:30 ~cache_read:40 ~cache_write:50
      ()
  in
  let sum = Usage.add a b in
  equal int ~msg:"input lane" 11 sum.Usage.input;
  equal int ~msg:"output lane" 22 sum.Usage.output;
  equal int ~msg:"reasoning lane" 33 sum.Usage.reasoning;
  equal int ~msg:"cache read lane" 44 sum.Usage.cache_read;
  equal int ~msg:"cache write lane" 55 sum.Usage.cache_write;
  equal int ~msg:"input total" 10 (Usage.input_total a);
  equal int ~msg:"output total" 5 (Usage.output_total a);
  equal int ~msg:"sum lanes" 15 (Usage.sum_lanes a);
  roundtrip "usage JSON" usage_value Usage.jsont a;
  List.iter
    (fun usage -> expect_invalid_arg "usage rejects negative lanes" usage)
    [
      (fun () -> Usage.make ~input:(-1) ~output:0 ());
      (fun () -> Usage.make ~input:0 ~output:(-1) ());
      (fun () -> Usage.make ~input:0 ~output:0 ~reasoning:(-1) ());
      (fun () -> Usage.make ~input:0 ~output:0 ~cache_read:(-1) ());
      (fun () -> Usage.make ~input:0 ~output:0 ~cache_write:(-1) ());
    ];
  let large = Usage.make ~input:max_int ~output:0 () in
  expect_invalid_arg "usage add overflow" (fun () ->
      Usage.add large (Usage.make ~input:1 ~output:0 ()))

let stop_contracts () =
  equal string ~msg:"stop label" "end_turn" (Stop.label Stop.end_turn);
  equal (option stop_value) ~msg:"canonical end_turn" (Some Stop.end_turn)
    (Stop.of_label "end_turn");
  equal stop_value ~msg:"other label" (Stop.other "vendor_stop")
    (Option.get (Stop.of_label "vendor_stop"));
  equal (opaque "stop view") ~msg:"stop view" Stop.End_turn
    (Stop.view Stop.end_turn);
  equal (opaque "stop view") ~msg:"other view" (Stop.Other "vendor_stop")
    (Stop.view (Stop.other "vendor_stop"));
  roundtrip "stop JSON" stop_value Stop.jsont (Stop.other "vendor_stop");
  expect_invalid_arg "reserved other stop" (fun () -> Stop.other "end_turn");
  expect_invalid_arg "invalid other stop" (fun () -> Stop.other "Vendor");
  equal (option stop_value) ~msg:"invalid label" None
    (Stop.of_label "bad-label")

let error_contracts () =
  let error =
    Error.make ~kind:Error.Transport ~phase:Error.Stream ~provider:openai
      ~status:503 ~request_id:"req_1" ~redacted_body:"unavailable"
      "provider unavailable"
  in
  equal string ~msg:"error label" "transport" (Error.label (Error.kind error));
  equal (option int) ~msg:"status" (Some 503) (Error.status error);
  equal (option string) ~msg:"request id" (Some "req_1")
    (Error.request_id error);
  roundtrip "error JSON" error_value Error.jsont error;
  expect_invalid_arg "empty error message" (fun () ->
      Error.make ~kind:Error.Provider "");
  expect_invalid_arg "low status" (fun () ->
      Error.make ~kind:Error.Provider ~status:99 "bad");
  expect_invalid_arg "high status" (fun () ->
      Error.make ~kind:Error.Provider ~status:600 "bad");
  expect_invalid_arg "reserved other error" (fun () ->
      Error.make ~kind:(Error.Other "auth") "bad");
  expect_invalid_arg "invalid other error" (fun () ->
      Error.make ~kind:(Error.Other "Bad") "bad")

let message_contracts () =
  let call = call () in
  let reasoning =
    Message.Assistant.Reasoning.make ~id:"rs_1" ~text:"thinking"
      ~encrypted:"ciphertext" ~signature:"sig_1" ()
  in
  let assistant =
    Message.Assistant.make
      [
        Message.Assistant.reasoning_part reasoning;
        Message.Assistant.text_part "I will use a tool.";
        Message.Assistant.tool_call call;
      ]
  in
  equal (list string) ~msg:"assistant texts" [ "I will use a tool." ]
    (Message.Assistant.texts assistant);
  equal
    (list (opaque "call"))
    ~msg:"assistant tool calls" [ call ]
    (Message.Assistant.tool_calls assistant);
  equal
    (list (opaque "reasoning"))
    ~msg:"assistant reasoning" [ reasoning ]
    (Message.Assistant.reasonings assistant);
  roundtrip "assistant JSON" (opaque "assistant") Message.Assistant.jsont
    assistant;
  let empty_assistant = Message.Assistant.empty in
  equal (list string) ~msg:"empty assistant texts" []
    (Message.Assistant.texts empty_assistant);
  equal
    (list (opaque "call"))
    ~msg:"empty assistant tool calls" []
    (Message.Assistant.tool_calls empty_assistant);
  equal
    (list (opaque "reasoning"))
    ~msg:"empty assistant reasoning" []
    (Message.Assistant.reasonings empty_assistant);
  roundtrip "empty assistant JSON" (opaque "assistant") Message.Assistant.jsont
    empty_assistant;
  roundtrip "message JSON" (opaque "message") Message.jsont
    (Message.assistant assistant);
  expect_invalid_arg "empty reasoning" (fun () ->
      Message.Assistant.Reasoning.make ());
  expect_invalid_arg "empty reasoning text" (fun () ->
      Message.Assistant.Reasoning.make ~text:"" ());
  expect_invalid_arg "empty assistant parts" (fun () ->
      Message.Assistant.make []);
  expect_invalid_arg "empty assistant text" (fun () ->
      Message.Assistant.text "");
  expect_invalid_arg "empty system" (fun () -> Message.system "");
  expect_invalid_arg "empty developer" (fun () -> Message.developer "");
  expect_invalid_arg "empty user" (fun () -> Message.user []);
  expect_invalid_arg "empty user text" (fun () -> Message.user_text "")

let transcript_accepts_ordinary_messages () =
  let transcript = ready_transcript () in
  equal bool ~msg:"ready transcript" true (Transcript.is_ready transcript);
  equal int ~msg:"message count" 2
    (List.length (Transcript.messages transcript));
  roundtrip "transcript JSON" (opaque "transcript") Transcript.jsont transcript

let transcript_tool_loop () =
  let first = call ~id:"call_1" () in
  let second = call ~id:"call_2" () in
  let assistant = Message.assistant (assistant_with_calls [ first; second ]) in
  let transcript = Transcript.add_exn assistant (ready_transcript ()) in
  equal bool ~msg:"waiting for tools" true
    (not (Transcript.is_ready transcript));
  equal
    (list (opaque "call"))
    ~msg:"pending calls preserve assistant order" [ first; second ]
    (Transcript.pending transcript);
  let transcript =
    match
      Transcript.add
        (Message.tool_result (Tool.Result.text second "second result"))
        transcript
    with
    | Ok transcript -> transcript
    | Error error -> failf "answer second failed: %a" Transcript.Error.pp error
  in
  equal
    (list (opaque "call"))
    ~msg:"remaining pending call" [ first ]
    (Transcript.pending transcript);
  let transcript =
    match
      Transcript.add (Message.tool_result (Tool.Result.empty first)) transcript
    with
    | Ok transcript -> transcript
    | Error error -> failf "answer first failed: %a" Transcript.Error.pp error
  in
  equal bool ~msg:"ready after all results" true
    (Transcript.is_ready transcript);
  equal int ~msg:"messages include two results" 5
    (List.length (Transcript.messages transcript))

let transcript_rejects_invalid_tool_order () =
  let first = call ~id:"call_1" () in
  let second = call ~id:"call_2" () in
  let transcript =
    Transcript.add_exn
      (Message.assistant (assistant_with_calls [ first ]))
      (ready_transcript ())
  in
  expect_error "ordinary message while pending"
    (Transcript.add (Message.user_text "continue") transcript)
    (fun error ->
      equal transcript_error ~msg:"pending error"
        (Transcript.Error.Pending_tool_results [ first ]) error);
  expect_error "unknown tool result"
    (Transcript.add
       (Message.tool_result (Tool.Result.text second "unknown"))
       transcript)
    (fun error ->
      equal transcript_error ~msg:"unknown error"
        (Transcript.Error.Unknown_tool_result { call_id = "call_2" })
        error);
  let wrong_name =
    Tool.Result.make_raw ~call_id:"call_1" ~name:"other_tool" []
  in
  expect_error "name mismatch"
    (Transcript.add (Message.tool_result wrong_name) transcript)
    (fun error ->
      equal transcript_error ~msg:"mismatch error"
        (Transcript.Error.Tool_result_name_mismatch
           { call_id = "call_1"; expected = "read_file"; actual = "other_tool" })
        error);
  let duplicate_call = call ~id:"call_1" ~name:"read_file" () in
  expect_error "duplicate tool call id"
    (Transcript.add
       (Message.assistant (assistant_with_calls [ first; duplicate_call ]))
       (ready_transcript ()))
    (fun error ->
      equal transcript_error ~msg:"duplicate call"
        (Transcript.Error.Duplicate_tool_call { call_id = "call_1" })
        error);
  expect_error "tool result without call"
    (Transcript.add
       (Message.tool_result (Tool.Result.empty first))
       (ready_transcript ()))
    (fun error ->
      match error with
      | Transcript.Error.Tool_result_without_call result ->
          equal string ~msg:"orphan result id" "call_1"
            (Tool.Result.call_id result)
      | Transcript.Error.Tool_result_name_mismatch _
      | Transcript.Error.Unknown_tool_result _
      | Transcript.Error.Duplicate_tool_result _
      | Transcript.Error.Duplicate_tool_call _
      | Transcript.Error.Pending_tool_results _ ->
          failf "unexpected transcript error")

let transcript_rejects_duplicate_tool_result () =
  let first = call ~id:"call_1" () in
  let second = call ~id:"call_2" () in
  let transcript =
    Transcript.add_exn
      (Message.assistant (assistant_with_calls [ first; second ]))
      (ready_transcript ())
  in
  let transcript =
    match
      Transcript.add (Message.tool_result (Tool.Result.empty first)) transcript
    with
    | Ok transcript -> transcript
    | Error error -> failf "first answer failed: %a" Transcript.Error.pp error
  in
  expect_error "duplicate tool result"
    (Transcript.add
       (Message.tool_result (Tool.Result.text first "again"))
       transcript)
    (fun error ->
      equal transcript_error ~msg:"duplicate result"
        (Transcript.Error.Duplicate_tool_result { call_id = "call_1" })
        error)

let transcript_of_list_agrees_with_add () =
  let first = call ~id:"call_1" () in
  let messages =
    [
      Message.developer "You are Spice.";
      Message.user_text "Use a tool.";
      Message.assistant (assistant_with_calls [ first ]);
      Message.tool_result (Tool.Result.text first "contents");
      Message.assistant_text "Done.";
    ]
  in
  let from_list =
    match Transcript.of_list messages with
    | Ok transcript -> transcript
    | Error error -> failf "of_list failed: %a" Transcript.Error.pp error
  in
  let from_add =
    List.fold_left
      (fun transcript message -> Transcript.add_exn message transcript)
      Transcript.empty messages
  in
  equal (opaque "transcript") ~msg:"of_list and add agree" from_add from_list;
  let invalid_messages = List.rev messages in
  is_true ~msg:"invalid order rejected"
    (Result.is_error (Transcript.of_list invalid_messages))

let transcript_last_assistant () =
  let assistant_texts msg = function
    | Some assistant -> Message.Assistant.texts assistant
    | None -> failf "%s: expected an assistant message" msg
  in
  (* No assistant message yet. *)
  is_true ~msg:"no assistant message yields None"
    (Option.is_none (Transcript.last_assistant (ready_transcript ())));
  (* The most recent assistant is returned, past an intervening user turn. *)
  let two_turns =
    Transcript.of_list_exn
      [
        Message.developer "You are Spice.";
        Message.user_text "First question.";
        Message.assistant_text "First.";
        Message.user_text "Second question.";
        Message.assistant_text "Second.";
      ]
  in
  equal (list string) ~msg:"returns the most recent assistant's texts"
    [ "Second." ]
    (assistant_texts "two turns" (Transcript.last_assistant two_turns));
  (* An empty assistant turn (no visible text) is still returned unfiltered. *)
  let empty_turn =
    Transcript.of_list_exn
      [
        Message.developer "You are Spice.";
        Message.user_text "Refactor a.ml.";
        Message.assistant Message.Assistant.empty;
      ]
  in
  equal (list string) ~msg:"an empty assistant turn is returned, not skipped" []
    (assistant_texts "empty turn" (Transcript.last_assistant empty_turn));
  (* A tool-call-only assistant (with pending calls) is returned too. *)
  let tool_turn =
    Transcript.add_exn
      (Message.assistant (assistant_with_calls [ call () ]))
      (ready_transcript ())
  in
  is_true ~msg:"transcript with a pending tool call is not ready"
    (not (Transcript.is_ready tool_turn));
  equal int ~msg:"a tool-call-only assistant is returned" 1
    (match Transcript.last_assistant tool_turn with
    | Some assistant -> List.length (Message.Assistant.tool_calls assistant)
    | None -> failf "expected the tool-call assistant message")

let request_contracts () =
  let transcript = ready_transcript () in
  let declared_tool = tool () in
  let options = Request.Options.make ~max_output_tokens:123 () in
  let prelude_messages =
    [
      Message.system "host system";
      Message.developer "host developer";
      Message.user_text "host contextual user instructions";
    ]
  in
  let prelude =
    match Request.Prelude.make prelude_messages with
    | Ok prelude -> prelude
    | Error error -> failf "prelude failed: %a" Request.Error.pp error
  in
  let request =
    Request.make_exn ~model:gpt ~prelude ~tools:[ declared_tool ] ~options
      ~cache_key:"session-1" transcript
  in
  equal model_value ~msg:"request model" gpt (Request.model request);
  equal
    (list (opaque "tool"))
    ~msg:"request tools" [ declared_tool ] (Request.tools request);
  equal
    (list (opaque "message"))
    ~msg:"request prelude" prelude_messages
    (Request.Prelude.messages (Request.prelude request));
  equal int ~msg:"transcript excludes prelude"
    (List.length (Transcript.messages transcript))
    (List.length (Transcript.messages (Request.transcript request)));
  equal
    (list (opaque "message"))
    ~msg:"request messages are prelude then transcript"
    (prelude_messages @ Transcript.messages transcript)
    (Request.messages request);
  expect_error "assistant prelude rejected"
    (Request.Prelude.make [ Message.assistant_text "not host context" ])
    (fun error ->
      match error with
      | Request.Error.Invalid_prelude_message (Message.Assistant _) -> ()
      | Request.Error.Empty_transcript | Request.Error.Pending_tool_results _
      | Request.Error.Duplicate_tool _ | Request.Error.Tool_choice_without_tools
      | Request.Error.Unknown_tool_choice _
      | Request.Error.Invalid_prelude_message _ ->
          failf "unexpected request error");
  let appended_message = Message.user_text "appended host context" in
  (match Request.Prelude.append prelude [ appended_message ] with
  | Error error -> failf "prelude append failed: %a" Request.Error.pp error
  | Ok appended ->
      equal
        (list (opaque "message"))
        ~msg:"append keeps existing messages and order"
        (prelude_messages @ [ appended_message ])
        (Request.Prelude.messages appended));
  (match Request.append_prelude request [ appended_message ] with
  | Error error ->
      failf "request prelude append failed: %a" Request.Error.pp error
  | Ok appended ->
      equal model_value ~msg:"append_prelude keeps model" gpt
        (Request.model appended);
      equal
        (list (opaque "tool"))
        ~msg:"append_prelude keeps tools" [ declared_tool ]
        (Request.tools appended);
      equal (opaque "options") ~msg:"append_prelude keeps options" options
        (Request.options appended);
      equal (option int) ~msg:"append_prelude keeps max output tokens"
        (Some 123)
        (Request.Options.max_output_tokens (Request.options appended));
      equal (option string) ~msg:"append_prelude keeps cache key"
        (Some "session-1")
        (Request.cache_key appended);
      equal (opaque "transcript") ~msg:"append_prelude keeps transcript"
        transcript
        (Request.transcript appended);
      equal
        (list (opaque "message"))
        ~msg:"append_prelude updates message order"
        (prelude_messages @ [ appended_message ]
        @ Transcript.messages transcript)
        (Request.messages appended));
  expect_error "assistant message rejected on append"
    (Request.Prelude.append prelude
       [ Message.assistant_text "not host context" ])
    (fun error ->
      match error with
      | Request.Error.Invalid_prelude_message (Message.Assistant _) -> ()
      | Request.Error.Empty_transcript | Request.Error.Pending_tool_results _
      | Request.Error.Duplicate_tool _ | Request.Error.Tool_choice_without_tools
      | Request.Error.Unknown_tool_choice _
      | Request.Error.Invalid_prelude_message _ ->
          failf "unexpected request error");
  expect_error "assistant message rejected by request append"
    (Request.append_prelude request
       [ Message.assistant_text "not host context" ])
    (fun error ->
      match error with
      | Request.Error.Invalid_prelude_message (Message.Assistant _) -> ()
      | Request.Error.Empty_transcript | Request.Error.Pending_tool_results _
      | Request.Error.Duplicate_tool _ | Request.Error.Tool_choice_without_tools
      | Request.Error.Unknown_tool_choice _
      | Request.Error.Invalid_prelude_message _ ->
          failf "unexpected request error");
  expect_error "empty transcript rejected"
    (Request.make ~model:gpt Transcript.empty) (fun error ->
      equal request_error ~msg:"empty request" Request.Error.Empty_transcript
        error);
  let pending =
    Transcript.add_exn
      (Message.assistant (assistant_with_calls [ call () ]))
      transcript
  in
  expect_error "pending transcript rejected" (Request.make ~model:gpt pending)
    (fun error ->
      match error with
      | Request.Error.Pending_tool_results calls ->
          equal int ~msg:"pending request call count" 1 (List.length calls)
      | Request.Error.Empty_transcript | Request.Error.Invalid_prelude_message _
      | Request.Error.Duplicate_tool _ | Request.Error.Tool_choice_without_tools
      | Request.Error.Unknown_tool_choice _ ->
          failf "unexpected request error");
  expect_error "duplicate tools rejected"
    (Request.make ~model:gpt ~tools:[ tool (); tool () ] transcript)
    (fun error ->
      equal request_error ~msg:"duplicate tools"
        (Request.Error.Duplicate_tool "read_file") error);
  expect_error "required tool choice needs tools"
    (Request.make ~model:gpt
       ~options:(Request.Options.make ~tool_choice:Request.Options.Required ())
       transcript)
    (fun error ->
      equal request_error ~msg:"required tools"
        Request.Error.Tool_choice_without_tools error);
  expect_error "named tool must be declared"
    (Request.make ~model:gpt ~tools:[ declared_tool ]
       ~options:
         (Request.Options.make ~tool_choice:(Request.Options.Tool "write_file")
            ())
       transcript)
    (fun error ->
      equal request_error ~msg:"unknown choice"
        (Request.Error.Unknown_tool_choice "write_file") error);
  expect_invalid_arg "invalid named tool choice" (fun () ->
      Request.Options.make ~tool_choice:(Request.Options.Tool "bad name") ());
  expect_invalid_arg "schema response format needs name" (fun () ->
      Request.Options.make
        ~response_format:
          (Request.Options.Json_schema { name = ""; schema; strict = true })
        ());
  expect_invalid_arg "schema response format needs object schema" (fun () ->
      Request.Options.make
        ~response_format:
          (Request.Options.Json_schema
             { name = "answer"; schema = Json.string "bad"; strict = true })
        ())

let client_contracts () =
  let request = Request.make_exn ~model:gpt (ready_transcript ()) in
  let terminal = response () in
  let seen_cancelled = ref false in
  let client =
    Client.make ~provider:openai
      ~run:(fun ~cancelled request ->
        seen_cancelled := cancelled ();
        equal model_value ~msg:"client receives request" gpt
          (Request.model request);
        Ok (Stream.of_list [ Stream.Finished terminal ]))
      ()
  in
  equal provider_value ~msg:"client provider" openai (Client.provider client);
  equal bool ~msg:"client accepts provider model" true
    (Client.accepts client gpt);
  equal bool ~msg:"client rejects other provider model" false
    (Client.accepts client (model ~provider:anthropic "claude"));
  let collected =
    match Client.response ~cancelled:(fun () -> true) client request with
    | Ok response -> response
    | Error error -> failf "client response failed: %a" Error.pp error
  in
  equal bool ~msg:"cancellation callback passed to run" true !seen_cancelled;
  equal (opaque "response") ~msg:"terminal response collected" terminal
    collected;
  let streamed =
    Client.make ~provider:openai
      ~run:(fun ~cancelled:_ _ ->
        Ok
          (Stream.of_list
             [
               Stream.Event (Stream.Event.text_delta "he");
               Stream.Event (Stream.Event.reasoning_summary_delta "why");
               Stream.Event (Stream.Event.text_delta "llo");
               Stream.Finished terminal;
             ]))
      ()
  in
  let observed = ref [] in
  let streamed_response =
    match
      Client.response
        ~on_event:(fun event -> observed := event :: !observed)
        streamed request
    with
    | Ok response -> response
    | Error error -> failf "streamed response failed: %a" Error.pp error
  in
  equal (opaque "response")
    ~msg:"terminal response collected under on_event" terminal streamed_response;
  equal
    (list (opaque "stream event"))
    ~msg:"on_event observes every live event in stream order"
    [
      Stream.Event.text_delta "he";
      Stream.Event.reasoning_summary_delta "why";
      Stream.Event.text_delta "llo";
    ]
    (List.rev !observed);
  let wrong_request =
    Request.make_exn
      ~model:(model ~provider:anthropic "claude")
      (ready_transcript ())
  in
  expect_error "wrong provider rejected" (Client.stream client wrong_request)
    (fun error ->
      equal string ~msg:"wrong provider error kind" "invalid_request"
        (Error.label (Error.kind error));
      equal (option provider_value) ~msg:"wrong provider error provider"
        (Some openai) (Error.provider error));
  let responses_only =
    Client.make ~provider:openai
      ~accepts:(fun model ->
        Provider.equal openai (Model.provider model)
        && Model.Api.equal responses (Model.api model))
      ~run:(fun ~cancelled:_ _ ->
        Ok (Stream.of_list [ Stream.Finished terminal ]))
      ()
  in
  let wrong_api_request =
    Request.make_exn
      ~model:(model ~api:(Model.Api.make "chat") "gpt-5")
      (ready_transcript ())
  in
  expect_error "wrong API rejected"
    (Client.stream responses_only wrong_api_request) (fun error ->
      equal string ~msg:"wrong API error kind" "invalid_request"
        (Error.label (Error.kind error)));
  let cancelled_client =
    Client.make ~provider:openai
      ~run:(fun ~cancelled:_ _ ->
        Error (Error.make ~kind:Error.Cancelled "cancelled before startup"))
      ()
  in
  expect_error "startup cancellation returned"
    (Client.response cancelled_client request) (fun error ->
      equal string ~msg:"startup cancellation kind" "cancelled"
        (Error.label (Error.kind error)))

let response_contracts () =
  let assistant = Message.Assistant.text "Done." in
  let response =
    Response.make ~model:gpt ~response_model:"gpt-5-2026-05-01"
      ~response_id:"resp_1" ~provider_stop:"stop" ~stop:Stop.end_turn
      ~usage:(Usage.make ~input:1 ~output:2 ())
      ~reasoning_summary:[ "summary" ] assistant
  in
  equal (opaque "assistant") ~msg:"assistant retained" assistant
    (Response.assistant response);
  equal (opaque "message") ~msg:"response message"
    (Message.assistant assistant)
    (Response.message response);
  equal (list string) ~msg:"response texts" [ "Done." ]
    (Response.texts response);
  equal string ~msg:"response text" "Done." (Response.text response);
  equal bool ~msg:"response has no tools" false
    (Response.has_tool_calls response);
  equal (option string) ~msg:"response id" (Some "resp_1")
    (Response.response_id response);
  equal (list string) ~msg:"reasoning summary" [ "summary" ]
    (Response.reasoning_summary response);
  roundtrip "response JSON" (opaque "response") Response.jsont response;
  expect_invalid_arg "empty response model" (fun () ->
      Response.make ~model:gpt ~response_model:"" assistant);
  expect_invalid_arg "empty response id" (fun () ->
      Response.make ~model:gpt ~response_id:"" assistant);
  expect_invalid_arg "empty provider stop" (fun () ->
      Response.make ~model:gpt ~provider_stop:"" assistant);
  expect_invalid_arg "empty reasoning summary" (fun () ->
      Response.make ~model:gpt ~reasoning_summary:[ "" ] assistant)

let stream_contracts () =
  let text = Stream.Event.text_delta "hello" in
  let usage = Stream.Event.usage (Usage.make ~input:1 ~output:0 ()) in
  let response = response () in
  let closed = ref 0 in
  let stream =
    Stream.of_list
      ~close:(fun () -> incr closed)
      [
        Stream.Event text;
        Stream.Event usage;
        Stream.Finished response;
        Stream.Event (Stream.Event.text_delta "hidden");
      ]
  in
  equal
    (option (opaque "stream item"))
    ~msg:"first event" (Some (Stream.Event text)) (Stream.next stream);
  equal
    (option (opaque "stream item"))
    ~msg:"second event" (Some (Stream.Event usage)) (Stream.next stream);
  equal
    (option (opaque "stream item"))
    ~msg:"finished" (Some (Stream.Finished response)) (Stream.next stream);
  equal int ~msg:"closed after terminal" 1 !closed;
  equal
    (option (opaque "stream item"))
    ~msg:"closed hides later items" None (Stream.next stream);
  Stream.close stream;
  equal int ~msg:"close idempotent" 1 !closed;
  let failed =
    Stream.of_list
      [
        Stream.Failed
          (Error.make ~kind:Error.Provider ~phase:Error.Stream "provider failed");
        Stream.Event text;
      ]
  in
  begin match Stream.collect failed with
  | Error error ->
      equal string ~msg:"failed stream error" "provider failed"
        (Error.message error)
  | Ok _ -> failf "expected failed stream"
  end;
  let folded_failure =
    Error.make ~kind:Error.Provider ~phase:Error.Stream "fold failed"
  in
  begin match
    Stream.fold_events
      (Stream.of_list [ Stream.Event text; Stream.Failed folded_failure ])
      ~init:[]
      ~f:(fun acc event -> acc @ [ event ])
  with
  | Error error ->
      equal error_value ~msg:"fold returns stream failure" folded_failure error
  | Ok _ -> failf "expected fold failure"
  end;
  let malformed_closed = ref 0 in
  let malformed =
    Stream.of_list
      ~close:(fun () -> incr malformed_closed)
      [ Stream.Event text ]
  in
  begin match Stream.next malformed with
  | Some (Stream.Event _) -> ()
  | None | Some (Stream.Finished _) | Some (Stream.Failed _) ->
      failf "expected first malformed event"
  end;
  begin match Stream.next malformed with
  | Some (Stream.Failed error) ->
      equal string ~msg:"malformed kind" "malformed_stream"
        (Error.label (Error.kind error));
      equal (opaque "error phase") ~msg:"malformed phase" Error.Stream
        (Error.phase error)
  | None | Some (Stream.Event _) | Some (Stream.Finished _) ->
      failf "expected malformed stream error"
  end;
  equal int ~msg:"malformed closes once" 1 !malformed_closed;
  equal
    (option (opaque "stream item"))
    ~msg:"malformed then closed" None (Stream.next malformed);
  let raised_closed = ref 0 in
  let raised =
    Stream.make
      ~close:(fun () -> incr raised_closed)
      (fun () ->
        let backend = Eio_unix.Unix_error (Unix.ECONNRESET, "readv", "") in
        let err = Eio.Net.E (Eio.Net.Connection_reset backend) in
        raise (Eio.Exn.create err))
  in
  begin match Stream.next raised with
  | Some (Stream.Failed error) ->
      equal string ~msg:"raised stream kind" "transport"
        (Error.label (Error.kind error));
      equal (opaque "error phase") ~msg:"raised stream phase" Error.Stream
        (Error.phase error);
      equal bool ~msg:"raised stream message includes connection reset" true
        (String.starts_with ~prefix:"Eio.Io Net Connection_reset"
           (Error.message error))
  | None | Some (Stream.Event _) | Some (Stream.Finished _) ->
      failf "expected raised stream transport error"
  end;
  equal int ~msg:"raised stream closes once" 1 !raised_closed;
  equal
    (option (opaque "stream item"))
    ~msg:"raised stream then closed" None (Stream.next raised);
  begin match Stream.collect (Stream.of_list [ Stream.Event text ]) with
  | Error error ->
      equal string ~msg:"collect malformed kind" "malformed_stream"
        (Error.label (Error.kind error))
  | Ok _ -> failf "expected malformed collect"
  end;
  let folded =
    Stream.fold_events
      (Stream.of_list
         [ Stream.Event text; Stream.Event usage; Stream.Finished response ])
      ~init:[]
      ~f:(fun acc event -> acc @ [ event ])
  in
  begin match folded with
  | Ok (events, terminal) ->
      equal (list (opaque "event")) ~msg:"fold order" [ text; usage ] events;
      equal (opaque "response") ~msg:"fold response" response terminal
  | Error error -> failf "fold failed: %a" Error.pp error
  end;
  let iterated = ref [] in
  begin match
    Stream.iter_events
      (Stream.of_list
         [ Stream.Event text; Stream.Event usage; Stream.Finished response ])
      ~f:(fun event -> iterated := !iterated @ [ event ])
  with
  | Ok terminal ->
      equal (opaque "response") ~msg:"iter response" response terminal
  | Error error -> failf "iter failed: %a" Error.pp error
  end;
  equal (list (opaque "event")) ~msg:"iter order" [ text; usage ] !iterated;
  let closed_on_success = ref 0 in
  let value =
    Stream.use
      (Stream.of_list ~close:(fun () -> incr closed_on_success) [])
      (fun stream ->
        ignore stream;
        42)
  in
  equal int ~msg:"use returns callback value" 42 value;
  equal int ~msg:"use closes on success" 1 !closed_on_success;
  let closed_on_exception = ref 0 in
  let stream =
    Stream.of_list
      ~close:(fun () -> incr closed_on_exception)
      [ Stream.Event text; Stream.Finished response ]
  in
  begin match
    Stream.iter_events stream ~f:(fun event ->
        ignore event;
        raise Callback_failure)
  with
  | Ok _ | Error _ -> failf "expected callback exception"
  | exception Callback_failure -> ()
  end;
  equal int ~msg:"callback exception closes stream" 1 !closed_on_exception;
  expect_invalid_arg "empty text delta" (fun () -> Stream.Event.text_delta "");
  expect_invalid_arg "empty reasoning summary delta" (fun () ->
      Stream.Event.reasoning_summary_delta "");
  expect_invalid_arg "empty tool input key" (fun () ->
      Stream.Event.Tool_input.make ~key:"" ~input_delta:"{" ());
  expect_invalid_arg "empty tool input delta" (fun () ->
      Stream.Event.Tool_input.make ~key:"0" ~input_delta:"" ())

let codec_roundtrips () =
  let call = call () in
  let assistant = assistant_with_calls [ call ] in
  let transcript =
    Transcript.of_list_exn
      [
        Message.developer "You are Spice.";
        Message.user_text "Read a file.";
        Message.assistant assistant;
        Message.tool_result (Tool.Result.text call "contents");
        Message.assistant_text "Done.";
      ]
  in
  roundtrip "request options JSON" (opaque "request options")
    Request.Options.jsont
    (Request.Options.make ~tool_choice:(Request.Options.Tool "read_file")
       ~max_output_tokens:100 ~temperature:0.2
       ~reasoning_effort:Request.Options.Reasoning_effort.High
       ~response_format:
         (Request.Options.Json_schema { name = "answer"; schema; strict = true })
       ());
  let reasoning_efforts =
    let open Request.Options.Reasoning_effort in
    [ Disabled; Minimal; Low; Medium; High; Extra_high; Max ]
  in
  List.iter
    (fun effort ->
      roundtrip "reasoning effort JSON" (opaque "request options")
        Request.Options.jsont
        (Request.Options.make ~reasoning_effort:effort ()))
    reasoning_efforts;
  roundtrip "complex transcript JSON" (opaque "transcript") Transcript.jsont
    transcript;
  roundtrip "response JSON with metadata" (opaque "response") Response.jsont
    (Response.make ~model:gpt ~response_model:"gpt-5-2026-05-01"
       ~response_id:"resp_1" ~provider_stop:"end_turn" ~stop:Stop.end_turn
       ~usage:
         (Usage.make ~input:1 ~output:2 ~reasoning:3 ~cache_read:4
            ~cache_write:5 ())
       ~reasoning_summary:[ "summary" ]
       (Message.Assistant.text "Done."))

let codec_shapes () =
  let usage =
    Usage.make ~input:1 ~output:2 ~reasoning:3 ~cache_read:4 ~cache_write:5 ()
  in
  let call = call () in
  let transcript =
    Transcript.of_list_exn
      [
        Message.developer "You are Spice.";
        Message.user_text "Read a file.";
        Message.assistant (assistant_with_calls [ call ]);
        Message.tool_result (Tool.Result.text call "contents");
      ]
  in
  let model_json =
    json_object
      [
        ("provider", Json.string "openai");
        ("api", Json.string "responses");
        ("id", Json.string "gpt-5");
      ]
  in
  let text_json text =
    json_object [ ("type", Json.string "text"); ("text", Json.string text) ]
  in
  let call_json =
    json_object
      [
        ("id", Json.string "call_1");
        ("name", Json.string "read_file");
        ("input", json_object [ ("path", Json.string "a.ml") ]);
      ]
  in
  let assistant_json =
    json_object
      [
        ( "parts",
          json_array
            [
              text_json "I will use a tool.";
              json_object
                [ ("type", Json.string "tool_call"); ("tool_call", call_json) ];
            ] );
      ]
  in
  equal_json "stop JSON shape" (Json.string "end_turn")
    (encode Stop.jsont Stop.end_turn);
  equal_json "request options JSON shape"
    (json_object
       [
         ( "tool_choice",
           json_object
             [ ("type", Json.string "tool"); ("name", Json.string "read_file") ]
         );
         ("max_output_tokens", Json.int 100);
         ("temperature", Json.number 0.2);
         ("reasoning_effort", Json.string "high");
         ( "response_format",
           json_object
             [
               ("type", Json.string "json_schema");
               ("name", Json.string "answer");
               ("schema", schema);
               ("strict", Json.bool true);
             ] );
       ])
    (encode Request.Options.jsont
       (Request.Options.make ~tool_choice:(Request.Options.Tool "read_file")
          ~max_output_tokens:100 ~temperature:0.2
          ~reasoning_effort:Request.Options.Reasoning_effort.High
          ~response_format:
            (Request.Options.Json_schema
               { name = "answer"; schema; strict = true })
          ()));
  equal_json "transcript JSON shape"
    (json_object
       [
         ( "messages",
           json_array
             [
               json_object
                 [
                   ("role", Json.string "developer");
                   ("text", Json.string "You are Spice.");
                 ];
               json_object
                 [
                   ("role", Json.string "user");
                   ("content", json_array [ text_json "Read a file." ]);
                 ];
               json_object
                 [
                   ("role", Json.string "assistant");
                   ("assistant", assistant_json);
                 ];
               json_object
                 [
                   ("role", Json.string "tool_result");
                   ( "tool_result",
                     json_object
                       [
                         ("call_id", Json.string "call_1");
                         ("name", Json.string "read_file");
                         ("error", Json.bool false);
                         ("content", json_array [ text_json "contents" ]);
                       ] );
                 ];
             ] );
       ])
    (encode Transcript.jsont transcript);
  equal_json "response JSON shape"
    (json_object
       [
         ("model", model_json);
         ("response_model", Json.string "gpt-5-2026-05-01");
         ("response_id", Json.string "resp_1");
         ("provider_stop", Json.string "end_turn");
         ("stop", Json.string "end_turn");
         ( "usage",
           json_object
             [
               ("input", Json.int 1);
               ("output", Json.int 2);
               ("reasoning", Json.int 3);
               ("cache_read", Json.int 4);
               ("cache_write", Json.int 5);
             ] );
         ("reasoning_summary", json_array [ Json.string "summary" ]);
         ( "assistant",
           json_object [ ("parts", json_array [ text_json "Done." ]) ] );
       ])
    (encode Response.jsont
       (Response.make ~model:gpt ~response_model:"gpt-5-2026-05-01"
          ~response_id:"resp_1" ~provider_stop:"end_turn" ~stop:Stop.end_turn
          ~usage ~reasoning_summary:[ "summary" ]
          (Message.Assistant.text "Done.")))

let codec_rejections () =
  let call = call () in
  let bad_transcript =
    json_object
      [
        ( "messages",
          json_array
            [
              encode Message.jsont (Message.user_text "hi");
              encode Message.jsont
                (Message.tool_result (Tool.Result.empty call));
            ] );
      ]
  in
  expect_decode_error "codec rejects invalid transcript grammar"
    Transcript.jsont bad_transcript;
  expect_decode_error "codec rejects bad stop label" Stop.jsont
    (Json.string "bad-label");
  expect_decode_error "codec rejects invalid tool" Tool.jsont
    (json_object
       [
         ("name", Json.string "bad name");
         ("description", Json.string "Bad.");
         ("input_schema", schema);
       ]);
  expect_decode_error "codec rejects empty error message" Error.jsont
    (json_object
       [
         ("kind", Json.string "auth");
         ("phase", Json.string "startup");
         ("message", Json.string "");
       ])

let no_tool_request_lifecycle () =
  let transcript = ready_transcript () in
  let request = Request.make_exn ~model:gpt transcript in
  equal (opaque "transcript") ~msg:"request transcript" transcript
    (Request.transcript request);
  let response = Response.make ~model:gpt (Message.Assistant.text "Done.") in
  let transcript =
    match Transcript.add_response response transcript with
    | Ok transcript -> transcript
    | Error error -> failf "add response failed: %a" Transcript.Error.pp error
  in
  equal bool ~msg:"transcript remains ready" true
    (Transcript.is_ready transcript);
  ignore (Request.make_exn ~model:gpt transcript)

let tool_request_lifecycle () =
  let call = call () in
  let transcript =
    match
      Transcript.add
        (Message.assistant (assistant_with_calls [ call ]))
        (ready_transcript ())
    with
    | Ok transcript -> transcript
    | Error error ->
        failf "assistant append failed: %a" Transcript.Error.pp error
  in
  equal bool ~msg:"assistant tool call waits" true
    (not (Transcript.is_ready transcript));
  let transcript =
    match
      Transcript.add
        (Message.tool_result (Tool.Result.text call "contents"))
        transcript
    with
    | Ok transcript -> transcript
    | Error error -> failf "tool answer failed: %a" Transcript.Error.pp error
  in
  equal bool ~msg:"tool answer readies transcript" true
    (Transcript.is_ready transcript);
  ignore (Request.make_exn ~model:gpt ~tools:[ tool () ] transcript)

let stream_request_lifecycle () =
  let terminal = response ~assistant:(assistant_with_calls [ call () ]) () in
  let stream =
    Stream.of_list
      [
        Stream.Event (Stream.Event.text_delta "I will use a tool.");
        Stream.Event (Stream.Event.tool_call (call ()));
        Stream.Finished terminal;
      ]
  in
  match Stream.collect stream with
  | Error error -> failf "stream failed: %a" Error.pp error
  | Ok response ->
      let transcript =
        match Transcript.add_response response (ready_transcript ()) with
        | Ok transcript -> transcript
        | Error error ->
            failf "add response failed: %a" Transcript.Error.pp error
      in
      equal int ~msg:"only terminal response enters transcript" 3
        (List.length (Transcript.messages transcript));
      equal bool ~msg:"terminal tool call makes transcript pending" true
        (not (Transcript.is_ready transcript))

let retry_contracts () =
  let float_value = testable ~pp:Format.pp_print_float ~equal:Float.equal () in
  let after headers = Llm.Retry.after ~now:784_111_777. headers in
  equal (option float_value) ~msg:"retry-after-ms wins" (Some 1.5)
    (after [ ("Retry-After-Ms", "1500"); ("retry-after", "9") ]);
  equal (option float_value) ~msg:"numeric seconds" (Some 9.)
    (after [ ("Retry-After", "9") ]);
  (* now = 784111777 is 1994-11-06T08:49:37Z, the RFC 9110 example date. *)
  equal (option float_value) ~msg:"IMF-fixdate relative to now" (Some 23.)
    (after [ ("retry-after", "Sun, 06 Nov 1994 08:50:00 GMT") ]);
  equal (option float_value) ~msg:"past dates clamp to zero" (Some 0.)
    (after [ ("retry-after", "Sun, 06 Nov 1994 08:00:00 GMT") ]);
  equal (option float_value) ~msg:"garbage is ignored" None
    (after [ ("retry-after", "soon") ]);
  equal (option float_value) ~msg:"absent header" None (after []);
  equal int ~msg:"capacity budget deepens" 5
    (Llm.Retry.budget ~max_retries:2 ~status:429);
  equal int ~msg:"explicit larger budget wins" 7
    (Llm.Retry.budget ~max_retries:7 ~status:503);
  equal int ~msg:"generic statuses keep the base budget" 2
    (Llm.Retry.budget ~max_retries:2 ~status:500);
  equal int ~msg:"zero disables capacity retries too" 0
    (Llm.Retry.budget ~max_retries:0 ~status:429)

let () =
  run "spice.llm"
    [
      group "values"
        [
          test "provider contracts" provider_contracts;
          test "model contracts" model_contracts;
          test "content contracts" content_contracts;
          test "tool contracts" tool_contracts;
          test "usage contracts" usage_contracts;
          test "stop contracts" stop_contracts;
          test "error contracts" error_contracts;
          test "message contracts" message_contracts;
        ];
      group "transcript"
        [
          test "accepts ordinary messages" transcript_accepts_ordinary_messages;
          test "tool loop" transcript_tool_loop;
          test "rejects invalid tool order"
            transcript_rejects_invalid_tool_order;
          test "rejects duplicate tool result"
            transcript_rejects_duplicate_tool_result;
          test "of_list agrees with add" transcript_of_list_agrees_with_add;
          test "last assistant" transcript_last_assistant;
        ];
      group "request" [ test "contracts" request_contracts ];
      group "retry" [ test "contracts" retry_contracts ];
      group "client" [ test "contracts" client_contracts ];
      group "response" [ test "contracts" response_contracts ];
      group "stream" [ test "contracts" stream_contracts ];
      group "codecs"
        [
          test "roundtrips" codec_roundtrips;
          test "stable JSON shapes" codec_shapes;
          test "rejects invalid data" codec_rejections;
        ];
      group "workflows"
        [
          test "no-tool request lifecycle" no_tool_request_lifecycle;
          test "tool request lifecycle" tool_request_lifecycle;
          test "stream request lifecycle" stream_request_lifecycle;
        ];
    ]
