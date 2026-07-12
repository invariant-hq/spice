(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Config = Spice_host.Config
module Env = Spice_host.Env
module Runner = Spice_host.Runner
module Host_session = Spice_host.Session
module Session = Spice_session
module Store = Spice_session_store
module Llm = Spice_llm
module Tool = Spice_tool
module Permission = Spice_permission
module Json = Jsont.Json

let provider = Llm.Provider.make "openai"

let model =
  Llm.Model.make ~provider ~api:(Llm.Model.Api.make "responses") ~id:"gpt-test"

let config_paths env root =
  let process_env =
    Env.of_list
      [
        ("HOME", root);
        ("XDG_CONFIG_HOME", Filename.concat root "config");
        ("XDG_DATA_HOME", Filename.concat root "data");
        ("XDG_STATE_HOME", Filename.concat root "state");
      ]
  in
  match Config.Config_file.discover ~stdenv:env ~process_env ~cwd:root () with
  | Ok paths -> paths
  | Error error -> failf "config discovery failed: %a" Config.Error.pp error

let expect_config message = function
  | Ok value -> value
  | Error error -> failf "%s: %a" message Config.Error.pp error

let locked_edits_preserve_concurrent_updates () =
  Eio_main.run @@ fun env ->
  let root = Filename.temp_dir "spice_config_lock" "" in
  let paths = config_paths env root in
  let active = ref 0 in
  let maximum = ref 0 in
  let edit field value () =
    Config.Config_file.edit ~stdenv:env paths Config.Config_file.User
      ~f:(fun doc ->
        incr active;
        maximum := max !maximum !active;
        Eio.Time.sleep (Eio.Stdenv.clock env) 0.02;
        decr active;
        Config.Config_file.set field (Some value) doc)
  in
  let first = ref None in
  let second = ref None in
  Eio.Fiber.both
    (fun () ->
      first := Some (edit Config.Field.model "openai/gpt-first" ()))
    (fun () ->
      second := Some (edit Config.Field.small_model "openai/gpt-second" ()));
  let first = Option.get !first in
  let second = Option.get !second in
  ignore (expect_config "first edit" first);
  ignore (expect_config "second edit" second);
  equal int ~msg:"config transforms do not overlap" 1 !maximum;
  let doc =
    Config.Config_file.load ~stdenv:env paths Config.Config_file.User
    |> expect_config "load edited config"
  in
  equal (option string) ~msg:"first update survives" (Some "openai/gpt-first")
    (Config.Config_file.get Config.Field.model doc);
  equal (option string) ~msg:"second update survives"
    (Some "openai/gpt-second")
    (Config.Config_file.get Config.Field.small_model doc)

let rule_value =
  testable ~pp:Permission.Policy.Rule.pp ~equal:Permission.Policy.Rule.equal ()

let batch_rule_append_is_ordered_and_idempotent () =
  Eio_main.run @@ fun env ->
  let root = Filename.temp_dir "spice_config_rules" "" in
  let paths = config_paths env root in
  let allow kind =
    Permission.Policy.Rule.allow (Permission.Policy.Match.kind kind)
  in
  let read = allow `Read in
  let write = allow `Write in
  let command = allow `Command in
  Config.Config_file.add_user_permission_rules ~stdenv:env paths
    [ read; write; read ]
  |> expect_config "first rule append" |> ignore;
  Config.Config_file.add_user_permission_rules ~stdenv:env paths
    [ write; command ]
  |> expect_config "second rule append" |> ignore;
  let doc =
    Config.Config_file.load ~stdenv:env paths Config.Config_file.User
    |> expect_config "load rule config"
  in
  equal (list rule_value) ~msg:"rules retain first-seen order"
    [ read; write; command ]
    (Config.Config_file.permission_rules doc)

type reply_fixture = {
  store : Store.t;
  runner : Runner.t;
  document : Store.Document.t;
  rule : Permission.Policy.Rule.t;
  ran : bool ref;
}

let make_reply_fixture env ~save_user_permission_rules ~after_save =
  let root = Filename.temp_dir "spice_permission_reply" "" in
  let cwd = Spice_path.Abs.of_string_exn root in
  let store =
    Store.make ~fs:(Eio.Stdenv.fs env) ~clock:(Eio.Stdenv.clock env) ~root:cwd
  in
  let session =
    Session.create ~id:(Session.Id.of_string "permission-transaction") ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L) ()
  in
  let document =
    match Store.create store session with
    | Ok document -> document
    | Error error -> failf "session create failed: %a" Store.Error.pp error
  in
  let access = Permission.Access.custom ~subject:"alpha" "review_tool" in
  let request = Permission.Request.of_accesses [ access ] in
  let ran = ref false in
  let tool =
    Tool.make ~name:"review_tool" ~description:"Reviewed test tool."
      ~input:Tool.Input.empty
      ~output:(fun () -> Tool.Output.make ~text:"done" ())
      ~permissions:(fun () -> [ request ])
      ~run:(fun _context () ->
        ran := true;
        Tool.Result.completed ~output:() ())
      ()
  in
  let call =
    Llm.Tool.Call.make ~id:"call-1" ~name:"review_tool"
      ~input:(Json.object' []) ()
  in
  let responses =
    ref
      [
        Llm.Response.make ~model
          (Llm.Message.Assistant.make
             [ Llm.Message.Assistant.tool_call call ]);
        Llm.Response.make ~model (Llm.Message.Assistant.text "Done.");
      ]
  in
  let client =
    Llm.Client.make ~provider
      ~run:(fun ~cancelled:_ ~on_event:_ _request ->
        match !responses with
        | response :: rest ->
            responses := rest;
            Ok response
        | [] -> failwith "unexpected model request")
      ()
  in
  let run =
    Spice_session_run.Config.make ~tools:[ tool ]
      ~policy:(fun _ -> Permission.Policy.default) ()
  in
  let hooks =
    Host_session.with_after_save after_save Host_session.no_hooks
  in
  let runner =
    Runner.make ~store ~client ~model ~mode:None ~run
      ~save_user_permission_rules ~hooks ()
  in
  let start =
    Spice_protocol.Command.Start.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~input:(Session.Turn.Input.user_text "Use the tool.") ()
  in
  let document =
    match Runner.execute runner document (Spice_protocol.Command.Start start) with
    | Ok (document, Spice_protocol.Outcome.Waiting _) -> document
    | Ok _ -> failf "turn did not wait for permission"
    | Error error -> failf "turn start failed: %a" Spice_protocol.Error.pp error
  in
  let rule = Permission.Policy.Rule.allow (Permission.Policy.Match.exact access) in
  { store; runner; document; rule; ran }

let pending_permission document =
  let session = Store.Document.session document in
  match Session.State.waiting (Session.state session) with
  | Some (Session.Waiting.Permission requested) ->
      Session.Permission.Requested.id requested
  | Some (Session.Waiting.Host_tool _ | Session.Waiting.Tool_claim _) | None ->
      failf "session has no pending permission"

let user_answer rule =
  Session.Permission.Resolved.Allow
    (Session.Permission.Resolved.Family
       { lifetime = Session.Permission.Resolved.User; rules = [ rule ] })

let user_reply_saves_authority_before_resolution_and_effect () =
  Eio_main.run @@ fun env ->
  let phase = ref `Waiting in
  let save_user_permission_rules _rules =
    phase := `Config_saved;
    Ok "/test/config.json"
  in
  let after_save _document events =
    if
      List.exists
        (function Session.Event.Permission_resolved _ -> true | _ -> false)
        events
    then begin
      is_true ~msg:"config is saved before the resolution"
        (!phase = `Config_saved);
      phase := `Resolution_saved
    end
  in
  let fixture =
    make_reply_fixture env ~save_user_permission_rules ~after_save
  in
  let permission = pending_permission fixture.document in
  let result =
    Runner.execute fixture.runner fixture.document
      (Spice_protocol.Command.Reply
         {
           permission;
           answer = user_answer fixture.rule;
           via = None;
           message = None;
         })
  in
  (match result with
  | Ok (_, Spice_protocol.Outcome.Finished _) -> ()
  | Ok _ -> failf "permission reply did not finish the turn"
  | Error error -> failf "permission reply failed: %a" Spice_protocol.Error.pp error);
  is_true ~msg:"the resolution was saved before the tool ran"
    (!phase = `Resolution_saved && !(fixture.ran))

let partial_success_is_structured_and_does_not_execute () =
  Eio_main.run @@ fun env ->
  let saved = ref false in
  let save_user_permission_rules _rules =
    saved := true;
    Ok "/test/config.json"
  in
  let fixture =
    make_reply_fixture env ~save_user_permission_rules
      ~after_save:(fun _ _ -> ())
  in
  let changed =
    Store.Document.session fixture.document
    |> Session.set_title (Some "concurrent change")
  in
  (match Store.save fixture.store fixture.document changed with
  | Ok _ -> ()
  | Error error -> failf "concurrent save failed: %a" Store.Error.pp error);
  let permission = pending_permission fixture.document in
  match
    Runner.execute fixture.runner fixture.document
      (Spice_protocol.Command.Reply
         {
           permission;
           answer = user_answer fixture.rule;
           via = None;
           message = None;
         })
  with
  | Error
      (Spice_protocol.Error.Permission_rule_saved
        { path; resolution_error = Spice_protocol.Error.Conflict _ }) ->
      is_true ~msg:"config saver completed" !saved;
      equal string ~msg:"committed config path is retained" "/test/config.json"
        path;
      is_false ~msg:"the blocked tool did not run" !(fixture.ran)
  | Error error ->
      failf "unexpected reply error: %a" Spice_protocol.Error.pp error
  | Ok _ -> failf "stale permission reply unexpectedly succeeded"

let config_failure_keeps_permission_pending () =
  Eio_main.run @@ fun env ->
  let save_error =
    Spice_protocol.Error.Permission_rule_save_failed
      {
        path = "/test/config.json";
        message = "read-only filesystem";
        hints = [];
      }
  in
  let fixture =
    make_reply_fixture env
      ~save_user_permission_rules:(fun _ -> Error save_error)
      ~after_save:(fun _ _ -> ())
  in
  let permission = pending_permission fixture.document in
  (match
     Runner.execute fixture.runner fixture.document
       (Spice_protocol.Command.Reply
          {
            permission;
            answer = user_answer fixture.rule;
            via = None;
            message = None;
          })
   with
  | Error (Spice_protocol.Error.Permission_rule_save_failed _) -> ()
  | Error error ->
      failf "unexpected reply error: %a" Spice_protocol.Error.pp error
  | Ok _ -> failf "reply unexpectedly succeeded after config failure");
  is_false ~msg:"the blocked tool did not run" !(fixture.ran);
  let reloaded =
    match Store.load fixture.store (Session.Id.of_string "permission-transaction") with
    | Ok document -> document
    | Error error -> failf "session reload failed: %a" Store.Error.pp error
  in
  is_true ~msg:"permission remains pending after config failure"
    (Session.Permission.Id.equal permission (pending_permission reloaded))

let () =
  run "spice.permission.transaction"
    [
      test "locked config edits preserve concurrent updates"
        locked_edits_preserve_concurrent_updates;
      test "batch user-rule append is ordered and idempotent"
        batch_rule_append_is_ordered_and_idempotent;
      test "user reply saves authority before resolution and effect"
        user_reply_saves_authority_before_resolution_and_effect;
      test "partial success is structured and does not execute"
        partial_success_is_structured_and_does_not_execute;
      test "config failure keeps the permission pending"
        config_failure_keeps_permission_pending;
    ]
