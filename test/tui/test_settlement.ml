(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness
module Llm = Spice_llm
module Host = Spice_host
module Protocol = Spice_protocol
module Session = Spice_session

let obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let response ~model text =
  Llm.Response.make ~model ~stop:Llm.Response.Stop.end_turn
    (Llm.Message.Assistant.text text)

let spawn_response ~model =
  let call =
    Llm.Tool.Call.make ~id:"spawn-1" ~name:"spawn_subagent"
      ~input:
        (obj
           [
             ("role", Jsont.Json.string "explore");
             ("task", Jsont.Json.string "child never settles");
           ])
      ()
  in
  let assistant =
    Llm.Message.Assistant.make [ Llm.Message.Assistant.tool_call call ]
  in
  Llm.Response.make ~model ~stop:Llm.Response.Stop.tool_call assistant

let message_texts = function
  | Llm.Message.User content ->
      List.filter_map
        (function
          | Llm.Content.Text text -> Some text | Llm.Content.Media _ -> None)
        content
  | Llm.Message.Assistant assistant -> Llm.Message.Assistant.texts assistant
  | Llm.Message.Tool_result result -> Llm.Tool.Result.texts result
  | Llm.Message.System text | Llm.Message.Developer text -> [ text ]

let request_contains request fragment =
  Llm.Request.messages request
  |> List.concat_map message_texts
  |> List.exists (String.includes ~affix:fragment)

let resolve_once resolver value =
  ignore (Eio.Promise.try_resolve resolver value : bool)

let blocked_stream ~started ~model =
  let never, _never_resolver = Eio.Promise.create () in
  Llm.Stream.make (fun () ->
      resolve_once started ();
      Eio.Promise.await never;
      Some (Llm.Stream.Finished (response ~model "unreachable")))

let scripted_client ~child_started ~next_root_started =
  let provider = Llm.Provider.make "openai" in
  Llm.Client.make ~provider
    ~run:(fun ~cancelled:_ request ->
      let model = Llm.Request.model request in
      if request_contains request "child never settles" then
        Ok (blocked_stream ~started:child_started ~model)
      else if request_contains request "root follow-up" then
        Ok (blocked_stream ~started:next_root_started ~model)
      else if request_contains request "launched" then
        Ok
          (Llm.Stream.of_list
             [ Llm.Stream.Finished (response ~model "root settled") ])
      else
        Ok (Llm.Stream.of_list [ Llm.Stream.Finished (spawn_response ~model) ]))
    ()

let get_or_fail pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let make_start id prompt =
  Protocol.Command.Start.make
    ~id:(Session.Turn.Id.of_string id)
    ~input:(Session.Turn.Input.user_text prompt)
    ()

let turn_of_settlement = function
  | Ok (_, Protocol.Outcome.Finished { turn; _ }) -> Some turn
  | Ok (_, Protocol.Outcome.Waiting _) | Error _ -> None

let%expect_test
    "a durable root settlement is published before unrelated child teardown" =
  Project.with_temp "settlement-owner" @@ fun project ->
  let bindings = Project.bindings project in
  Project.apply bindings;
  let process_env = Project.env_snapshot bindings in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let config =
    Host.Config.load ~stdenv ~process_env ~cwd:(Project.root project) ()
    |> get_or_fail Host.Config.Error.pp
  in
  let host =
    Host.Host.load ~stdenv ~registry:Spice_host_builtin.registry ~config ()
    |> get_or_fail Host.Host.Error.pp
  in
  let workspace =
    Spice_workspace.single (Spice_workspace.Root.make (Host.Config.cwd config))
  in
  let sandbox =
    Host.Sandbox.resolve ~flag:Host.Sandbox.Mode.Danger_full_access
      ~env:(Host.Env.get process_env) ~workspace ()
  in
  let plan =
    Host.Run.plan ~workspace ~sandbox
      ~permission:(Host.Config.permission_posture config)
      ()
    |> get_or_fail Host.Sandbox.Gate_error.pp
  in
  let store = Host.Session.store ~stdenv host in
  let session = Session.Id.of_string "session-settlement-owner" in
  let run =
    Host.Run.start ~sw ~stdenv host plan ~store ~session
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ()
    |> get_or_fail Host.Host.Error.pp
  in
  Fun.protect
    ~finally:(fun () -> Host.Run.stop run)
    (fun () ->
      let model =
        Host.Models.for_select (Host.Host.catalog host) "openai/gpt-5.5"
        |> get_or_fail Host.Host.Error.pp
      in
      let child_started, resolve_child_started = Eio.Promise.create () in
      let next_root_started, resolve_next_root_started =
        Eio.Promise.create ()
      in
      let client =
        scripted_client ~child_started:resolve_child_started
          ~next_root_started:resolve_next_root_started
      in
      let runner =
        Host.Run.runner run ~mode:Protocol.Mode.Build ~model ~client
        |> get_or_fail Host.Host.Error.pp
      in
      let created_at =
        Eio.Time.now (Eio.Stdenv.clock stdenv)
        |> Session.Time.of_unix_seconds_float
      in
      let document =
        Host.Session.create ~store ~id:session ~cwd:(Host.Run.cwd run)
          ~created_at ()
        |> get_or_fail Protocol.Error.pp
      in
      let live = Host.Live.attach ~sw ~runner document in
      let first_turn = Session.Turn.Id.of_string "turn-root-first" in
      let terminal, resolve_terminal = Eio.Promise.create () in
      let settlements = ref [] in
      Host.Live.events live (function
        | Protocol.Event.Turn_finished { turn; _ }
          when Session.Turn.Id.equal turn first_turn ->
            resolve_once resolve_terminal ()
        | _ -> ());
      Host.Live.on_settled live (fun result ->
          Option.iter
            (fun turn -> settlements := turn :: !settlements)
            (turn_of_settlement result));
      Host.Live.submit live
        (Protocol.Command.Start (make_start "turn-root-first" "root request"));
      let clock = Eio.Stdenv.clock stdenv in
      Eio.Time.with_timeout_exn clock 5. (fun () ->
          Eio.Promise.await child_started;
          Eio.Promise.await terminal);
      (* The first turn is durable and its terminal event was observed. Under
         the old Run hook the drain is now waiting for the blocked child, before
         Live can publish the settlement. Queue the next turn, then force that
         exact post-commit interval. *)
      Host.Live.submit live
        (Protocol.Command.Start (make_start "turn-root-next" "root follow-up"));
      Host.Live.force_interrupt live;
      Eio.Time.with_timeout_exn clock 5. (fun () ->
          Eio.Promise.await next_root_started);
      List.rev !settlements
      |> List.iter (fun turn -> print_endline (Session.Turn.Id.to_string turn));
      [%expect {|turn-root-first|}])
