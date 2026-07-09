(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Tool = Spice_tool
module Json = Jsont.Json

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("text", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", json_array [ Json.string "text" ]);
      ("additionalProperties", Json.bool false);
    ]

let input_json text = json_object [ ("text", Json.string text) ]

let string_input =
  Jsont.Object.map ~kind:"tool input" Fun.id
  |> Jsont.Object.mem "text" Jsont.string ~enc:Fun.id
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
  |> Tool.Input.make ~schema

let output s = Tool.Output.make ~text:s ~json:(Json.string s) ()

let shell_request command =
  Spice_permission.Request.of_accesses
    [
      Spice_permission.Access.command
        (Spice_permission.Access.Command.shell command);
    ]

let request = shell_request "echo hi"
let tool_error = testable ~pp:Tool.Error.pp ~equal:( = ) ()

let expect_error msg result check =
  match result with
  | Ok value ->
      ignore value;
      failf "%s: expected error" msg
  | Error error -> check error

let tool ?permissions ?run name =
  let run =
    match run with
    | Some run -> run
    | None ->
        fun context input ->
          Tool.Context.emit context (Tool.Update.Text_delta input);
          Tool.Result.completed ~output:input ()
  in
  Tool.make ~name ~description:"Echo input text." ~input:string_input ~output
    ?permissions ~run ()

let decode_call ?(name = "echo") ?(input = input_json "hello") tools =
  match Tool.Call.decode tools ~name ~input () with
  | Ok call -> call
  | Error error -> failf "decode failed: %a" Tool.Error.pp error

let input_contracts () =
  equal bool ~msg:"schema is retained" true
    (Json.equal schema (Tool.Input.schema string_input));
  equal (result string string) ~msg:"runtime codec decodes" (Ok "hello")
    (Tool.Input.decode string_input (input_json "hello"));
  is_true ~msg:"runtime codec rejects malformed JSON"
    (Result.is_error (Tool.Input.decode string_input (json_object [])));
  expect_invalid_arg "input schema root must be object" (fun () ->
      Tool.Input.make Jsont.string ~schema:(Json.string "bad"));
  equal bool ~msg:"empty input schema is an object" true
    (match Tool.Input.schema Tool.Input.empty with
    | Jsont.Object _ -> true
    | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
    | Jsont.Array _ ->
        false);
  equal (result unit string) ~msg:"empty input accepts empty object" (Ok ())
    (Tool.Input.decode Tool.Input.empty (json_object []));
  is_true ~msg:"empty input rejects fields"
    (Result.is_error
       (Tool.Input.decode Tool.Input.empty
          (json_object [ ("x", Json.bool true) ])))

let output_contracts () =
  let plain = Tool.Output.make ~text:"done" () in
  equal string ~msg:"text" "done" (Tool.Output.text plain);
  equal (option bool) ~msg:"json default" None
    (Option.map (Json.equal (Json.bool true)) (Tool.Output.json plain));
  equal bool ~msg:"truncated default" false (Tool.Output.truncated plain);
  let structured =
    Tool.Output.make ~text:"trimmed" ~json:(Json.string "trimmed")
      ~truncated:true ()
  in
  equal (option bool) ~msg:"json" (Some true)
    (Option.map
       (Json.equal (Json.string "trimmed"))
       (Tool.Output.json structured));
  equal bool ~msg:"truncated" true (Tool.Output.truncated structured);
  expect_invalid_arg "text is required" (fun () -> Tool.Output.make ~text:"" ())

let output_retained_values () =
  let int_id : int Type.Id.t = Type.Id.make () in
  let other_int_id : int Type.Id.t = Type.Id.make () in
  let string_id : string Type.Id.t = Type.Id.make () in
  let plain = Tool.Output.make ~text:"done" () in
  equal (option int) ~msg:"absent by default" None
    (Tool.Output.value int_id plain);
  let packed =
    Tool.Output.make ~text:"done" ~value:(Tool.Output.pack int_id 42) ()
  in
  equal (option int) ~msg:"round-trip with the packing witness" (Some 42)
    (Tool.Output.value int_id packed);
  equal (option int) ~msg:"distinct witness of the same type" None
    (Tool.Output.value other_int_id packed);
  equal (option string) ~msg:"witness of a different type" None
    (Tool.Output.value string_id packed)

let output_json_projection () =
  let int_id : int Type.Id.t = Type.Id.make () in
  let structured_json = json_object [ ("ok", Json.bool true) ] in
  let output =
    Tool.Output.make ~text:"done" ~json:structured_json ~truncated:true
      ~value:(Tool.Output.pack int_id 42) ()
  in
  let projected = encode Tool.Output.jsont output in
  equal bool ~msg:"encoded projection has durable fields" true
    (Json.equal
       (json_object
          [
            ("text", Json.string "done");
            ("json", structured_json);
            ("truncated", Json.bool true);
          ])
       projected);
  let decoded = decode Tool.Output.jsont projected in
  equal string ~msg:"decoded text" "done" (Tool.Output.text decoded);
  equal (option bool) ~msg:"decoded json" (Some true)
    (Option.map (Json.equal structured_json) (Tool.Output.json decoded));
  equal bool ~msg:"decoded truncated" true (Tool.Output.truncated decoded);
  equal (option int) ~msg:"retained value is not serialized" None
    (Tool.Output.value int_id decoded);
  expect_invalid_arg "decoded projection rejects empty text" (fun () ->
      Json.decode Tool.Output.jsont
        (json_object
           [ ("text", Json.string ""); ("truncated", Json.bool false) ]))

let result_contracts () =
  let completed = Tool.Result.completed ~output:"ok" () in
  equal (option string) ~msg:"completed output" (Some "ok")
    (Tool.Result.output completed);
  equal (option string) ~msg:"completed message" None
    (Tool.Result.message completed);
  (match Tool.Result.status completed with
  | Tool.Result.Completed -> ()
  | Tool.Result.Failed _ | Tool.Result.Interrupted _ ->
      failf "unexpected non-completed status");
  let metadata = json_object [ ("path", Json.string "missing.txt") ] in
  let failed =
    Tool.Result.failed ~output:"partial" ~metadata `Not_found "missing"
  in
  equal (option string) ~msg:"failed output" (Some "partial")
    (Tool.Result.output failed);
  equal (option string) ~msg:"failed message" (Some "missing")
    (Tool.Result.message failed);
  (match Tool.Result.status failed with
  | Tool.Result.Failed
      { kind = `Not_found; message; metadata = Some actual_metadata } ->
      equal string ~msg:"failed status message" "missing" message;
      equal bool ~msg:"failed metadata" true
        (Json.equal metadata actual_metadata)
  | Tool.Result.Completed | Tool.Result.Interrupted _ | Tool.Result.Failed _ ->
      failf "unexpected failed status");
  let interrupted =
    Tool.Result.interrupted ~output:"partial" ~reason:"cancelled"
      ~cancelled:true ()
  in
  equal (option string) ~msg:"interrupted message" (Some "cancelled")
    (Tool.Result.message interrupted);
  (match Tool.Result.status interrupted with
  | Tool.Result.Interrupted { reason; cancelled } ->
      equal string ~msg:"interrupt reason" "cancelled" reason;
      equal bool ~msg:"interrupt cancelled" true cancelled
  | Tool.Result.Completed | Tool.Result.Failed _ ->
      failf "unexpected interrupted status");
  List.iter
    (fun failure ->
      equal (option string)
        ~msg:("failure label " ^ Tool.Result.failure_to_string failure)
        (Some (Tool.Result.failure_to_string failure))
        (Option.map Tool.Result.failure_to_string
           (Tool.Result.failure_of_string
              (Tool.Result.failure_to_string failure))))
    [
      `Invalid_input;
      `Permission_denied;
      `Not_found;
      `Stale;
      `Unavailable;
      `Timed_out;
      `Failed;
    ];
  equal (option string) ~msg:"unknown failure label" None
    (Option.map Tool.Result.failure_to_string
       (Tool.Result.failure_of_string "unknown"));
  expect_invalid_arg "failed message is required" (fun () ->
      Tool.Result.failed `Failed "");
  expect_invalid_arg "interrupted reason is required" (fun () ->
      Tool.Result.interrupted ~reason:"" ~cancelled:false ())

let tool_definition_contracts () =
  let echo = tool "echo" in
  equal string ~msg:"name" "echo" (Tool.name echo);
  equal string ~msg:"description" "Echo input text." (Tool.description echo);
  equal bool ~msg:"input schema" true
    (Json.equal schema (Tool.input_schema echo));
  expect_invalid_arg "name is required" (fun () -> tool "");
  expect_invalid_arg "description is required" (fun () ->
      Tool.make ~name:"bad" ~description:"" ~input:string_input ~output
        ~run:(fun context input ->
          ignore (Tool.Context.cancelled context);
          Tool.Result.completed ~output:input ())
        ())

let call_decode_errors () =
  let echo = tool "echo" in
  expect_error "duplicate names fail before lookup"
    (Tool.Call.decode [ echo; echo ] ~name:"missing" ~input:(json_object []) ())
    (fun error ->
      equal tool_error ~msg:"duplicate error" (Tool.Error.Duplicate_name "echo")
        error);
  expect_error "unknown tool"
    (Tool.Call.decode [ echo ] ~name:"missing" ~input:(input_json "hello") ())
    (fun error ->
      equal tool_error ~msg:"unknown tool" (Tool.Error.Unknown_tool "missing")
        error);
  expect_error "invalid input"
    (Tool.Call.decode [ echo ] ~name:"echo" ~input:(json_object []) ())
    (function
      | Tool.Error.Invalid_input { tool = "echo"; diagnostic } ->
          is_true ~msg:"diagnostic is populated"
            (not (String.is_empty diagnostic))
      | error -> failf "unexpected error: %a" Tool.Error.pp error)

let catalog_decodes_with_validated_tools () =
  let echo = tool "echo" in
  let other = tool "other" in
  let catalog =
    match Tool.Catalog.make [ echo; other ] with
    | Ok catalog -> catalog
    | Error error -> failf "catalog failed: %a" Tool.Error.pp error
  in
  equal (list string) ~msg:"catalog tools" [ "echo"; "other" ]
    (List.map Tool.name (Tool.Catalog.tools catalog));
  let call =
    match
      Tool.Catalog.decode catalog ~name:"echo" ~input:(input_json "hello") ()
    with
    | Ok call -> call
    | Error error -> failf "catalog decode failed: %a" Tool.Error.pp error
  in
  equal string ~msg:"catalog call tool" "echo" (Tool.Call.tool call);
  expect_error "catalog decode reports unknown tool"
    (Tool.Catalog.decode catalog ~name:"missing" ~input:(json_object []) ())
    (fun error ->
      equal tool_error ~msg:"unknown tool" (Tool.Error.Unknown_tool "missing")
        error);
  expect_error "catalog rejects duplicate names"
    (Tool.Catalog.make [ echo; echo ])
    (fun error ->
      equal tool_error ~msg:"duplicate error" (Tool.Error.Duplicate_name "echo")
        error)

let call_permissions_and_run_use_the_decoded_input () =
  let emitted = ref [] in
  let cancelled = ref false in
  let permissions input =
    if String.equal input "allow" then [ request ] else []
  in
  let run context input =
    equal bool ~msg:"context cancellation" !cancelled
      (Tool.Context.cancelled context);
    Tool.Context.emit context
      (Tool.Update.Progress { title = Some input; metadata = None });
    Tool.Result.completed ~output:("echo:" ^ input) ()
  in
  let call =
    decode_call [ tool "echo" ~permissions ~run ] ~input:(input_json "allow")
  in
  equal string ~msg:"call tool" "echo" (Tool.Call.tool call);
  equal int ~msg:"permissions from decoded input" 1
    (List.length (Tool.Call.permissions call));
  cancelled := true;
  let result =
    Tool.Call.run call
      ~cancelled:(fun () -> !cancelled)
      ~emit:(fun update -> emitted := update :: !emitted)
      ()
  in
  equal (option string) ~msg:"result text" (Some "echo:allow")
    (Option.map Tool.Output.text (Tool.Result.output result));
  equal (option bool) ~msg:"result json" (Some true)
    (Option.map
       (Json.equal (Json.string "echo:allow"))
       (Option.bind (Tool.Result.output result) Tool.Output.json));
  match !emitted with
  | [ Tool.Update.Progress { title = Some "allow"; metadata = None } ] -> ()
  | updates -> failf "unexpected updates: %d" (List.length updates)

let call_run_preserves_non_completed_status () =
  let run context input =
    ignore (Tool.Context.cancelled context);
    Tool.Result.failed ~output:("partial:" ^ input) `Stale "stale input"
  in
  let call = decode_call [ tool "echo" ~run ] ~input:(input_json "data") in
  let result = Tool.Call.run call () in
  equal (option string) ~msg:"partial output is projected" (Some "partial:data")
    (Option.map Tool.Output.text (Tool.Result.output result));
  equal (option string) ~msg:"failure message" (Some "stale input")
    (Tool.Result.message result);
  match Tool.Result.status result with
  | Tool.Result.Failed
      { kind = `Stale; message = "stale input"; metadata = None } ->
      ()
  | Tool.Result.Completed | Tool.Result.Interrupted _ | Tool.Result.Failed _ ->
      failf "unexpected run status"

let call_run_rejects_empty_projected_output () =
  let bad_tool =
    Tool.make ~name:"bad" ~description:"Bad output." ~input:string_input
      ~output:(fun _ -> Tool.Output.make ~text:"" ())
      ~run:(fun context input ->
        ignore (Tool.Context.cancelled context);
        Tool.Result.completed ~output:input ())
      ()
  in
  let call = decode_call [ bad_tool ] ~name:"bad" ~input:(input_json "hello") in
  expect_invalid_arg "projected output must have text" (fun () ->
      Tool.Call.run call ())

let error_diagnostics () =
  let cases =
    [
      (Tool.Error.Duplicate_name "echo", "duplicate tool name: echo");
      (Tool.Error.Unknown_tool "", "unknown tool");
      (Tool.Error.Unknown_tool "missing", "unknown tool: missing");
      ( Tool.Error.Invalid_input { tool = "echo"; diagnostic = "missing text" },
        "invalid input for tool echo: missing text" );
    ]
  in
  List.iter
    (fun (error, message) ->
      equal string ~msg:(message ^ " message") message
        (Tool.Error.message error);
      equal string ~msg:(message ^ " pp") message
        (Format.asprintf "%a" Tool.Error.pp error))
    cases

let () =
  run "spice.tool"
    [
      test "input contracts" input_contracts;
      test "output contracts" output_contracts;
      test "output retained values" output_retained_values;
      test "output json projection" output_json_projection;
      test "result contracts" result_contracts;
      test "tool definition contracts" tool_definition_contracts;
      test "call decode errors" call_decode_errors;
      test "catalog decodes with validated tools"
        catalog_decodes_with_validated_tools;
      test "call permissions and run use the decoded input"
        call_permissions_and_run_use_the_decoded_input;
      test "call run preserves non-completed status"
        call_run_preserves_non_completed_status;
      test "call run rejects empty projected output"
        call_run_rejects_empty_projected_output;
      test "error diagnostics" error_diagnostics;
    ]
