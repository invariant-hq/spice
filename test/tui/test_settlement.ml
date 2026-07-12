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
    ~run:(fun ~cancelled:_ ~on_event request ->
      let model = Llm.Request.model request in
      let stream =
        if request_contains request "child never settles" then
          blocked_stream ~started:child_started ~model
        else if request_contains request "root follow-up" then
          blocked_stream ~started:next_root_started ~model
        else if request_contains request "launched" then
          Llm.Stream.of_list
            [ Llm.Stream.Finished (response ~model "root settled") ]
        else Llm.Stream.of_list [ Llm.Stream.Finished (spawn_response ~model) ]
      in
      Llm.Stream.iter_events stream ~f:on_event)
    ()

let cancellation_client ~child_started =
  let provider = Llm.Provider.make "openai" in
  Llm.Client.make ~provider
    ~run:(fun ~cancelled:_ ~on_event request ->
      let model = Llm.Request.model request in
      let stream =
        if request_contains request "first child stalls" then
          blocked_stream ~started:child_started ~model
        else
          Llm.Stream.of_list
            [ Llm.Stream.Finished (response ~model "second child completed") ]
      in
      Llm.Stream.iter_events stream ~f:on_event)
    ()

let blocked_client ~started =
  let provider = Llm.Provider.make "openai" in
  Llm.Client.make ~provider
    ~run:(fun ~cancelled:_ ~on_event request ->
      let model = Llm.Request.model request in
      Llm.Stream.iter_events (blocked_stream ~started ~model) ~f:on_event)
    ()

let get_or_fail pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let trust_project ~stdenv ~process_env project =
  Host.Trust.trust ~stdenv ~process_env
    ~root:(Spice_path.Abs.of_string_exn (Project.root project))
    ()
  |> get_or_fail Host.Trust.Error.pp
  |> ignore

let make_start id prompt =
  Protocol.Command.Start.make
    ~id:(Session.Turn.Id.of_string id)
    ~input:(Session.Turn.Input.user_text prompt)
    ()

let turn_of_settlement = function
  | Ok (_, Protocol.Outcome.Finished { turn; _ }) -> Some turn
  | Ok (_, Protocol.Outcome.Waiting _) | Error _ -> None

let is_cancelled = function
  | Host.Jobs.Interrupted { cancelled = true; _ } -> true
  | Host.Jobs.Summary _ | Host.Jobs.Blocked_on _
  | Host.Jobs.Interrupted { cancelled = false; _ }
  | Host.Jobs.Failed_with _ | Host.Jobs.Wait_interrupted ->
      false

let%expect_test "run construction does not read a workspace-sized review source"
    =
  Project.with_temp "bounded-review-start" @@ fun project ->
  Project.write_scratch project "config/spice/config.json"
    {|{"notices":{"fswatch":false,"cr_comments":true,"dune_diagnostics":false,"dune_build":false}}|};
  let source = Project.path project "deep/review.ml" in
  Project.write project "deep/review.ml" "";
  Unix.truncate source (64 * 1024 * 1024);
  let bindings = Project.bindings project in
  Project.apply bindings;
  let process_env = Project.env_snapshot bindings in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  trust_project ~stdenv ~process_env project;
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
    Host.Sandbox.resolve ~sw ~flag:Host.Sandbox.Mode.Danger_full_access ~stdenv
      ~env:(Host.Env.get process_env)
      ~project_root:(Host.Config.project_root config) ~workspace ()
    |> get_or_fail Host.Sandbox.Resolve_error.pp
  in
  let plan =
    Host.Run.plan ~workspace ~sandbox
      ~permission:(Host.Config.permission_posture config)
      ()
    |> get_or_fail Host.Sandbox.Gate_error.pp
  in
  let store = Host.Session.store ~stdenv host in
  Gc.full_major ();
  let before = Gc.quick_stat () in
  let run =
    Host.Run.start ~sw ~stdenv host plan ~store
      ~session:(Session.Id.of_string "session-bounded-review-start")
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ()
    |> get_or_fail Host.Host.Error.pp
  in
  let after = Gc.quick_stat () in
  Host.Run.close run |> Result.get_ok;
  let major_words = after.Gc.major_words -. before.Gc.major_words in
  Printf.printf "construction allocation bounded: %b\n"
    (major_words < 4_000_000.);
  [%expect {| construction allocation bounded: true |}]

let%expect_test "an oversized watcher snapshot warns and run close stays bounded"
    =
  Project.with_temp "bounded-fswatch-start" @@ fun project ->
  Project.write_scratch project "config/spice/config.json"
    {|{"notices":{"fswatch":false,"cr_comments":true,"dune_diagnostics":false,"dune_build":false},"workspace":{"tooling":"off"}}|};
  let rec make_deep_tree parent remaining =
    if remaining > 0 then begin
      let child = Filename.concat parent "nested" in
      Unix.mkdir child 0o755;
      make_deep_tree child (remaining - 1)
    end
  in
  let dependencies = Project.path project "node_modules" in
  Unix.mkdir dependencies 0o755;
  make_deep_tree dependencies 80;
  let bindings = Project.bindings project in
  Project.apply bindings;
  let process_env = Project.env_snapshot bindings in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  trust_project ~stdenv ~process_env project;
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
    Host.Sandbox.resolve ~sw ~flag:Host.Sandbox.Mode.Danger_full_access ~stdenv
      ~env:(Host.Env.get process_env)
      ~project_root:(Host.Config.project_root config) ~workspace ()
    |> get_or_fail Host.Sandbox.Resolve_error.pp
  in
  let plan =
    Host.Run.plan ~workspace ~sandbox
      ~permission:(Host.Config.permission_posture config)
      ()
    |> get_or_fail Host.Sandbox.Gate_error.pp
  in
  let store = Host.Session.store ~stdenv host in
  let run =
    Host.Run.start ~sw ~stdenv host plan ~store
      ~session:(Session.Id.of_string "session-bounded-fswatch-start")
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ()
    |> get_or_fail Host.Host.Error.pp
  in
  let clock = Eio.Stdenv.clock stdenv in
  let warning =
    Eio.Time.with_timeout_exn clock 3.0 (fun () ->
        while Host.Notice_queue.is_empty (Host.Run.notices run) do
          Eio.Time.sleep clock 0.01
        done;
        let batch = Host.Notice_queue.take (Host.Run.notices run) in
        let notices = Host.Notice_queue.notices batch in
        Host.Notice_queue.commit batch;
        List.hd notices)
  in
  Printf.printf "watcher limit visible: %b\n"
    (String.equal (Protocol.Notice.title warning) "Filesystem watcher error"
    &&
    match Protocol.Notice.body warning with
    | Some body -> String.includes ~affix:"depth" body
    | None -> false);
  Eio.Time.with_timeout_exn clock 2.0 (fun () -> Host.Run.close run)
  |> Result.get_ok;
  print_endline "run close completed";
  [%expect
    {|
    watcher limit visible: true
    run close completed
    |}]

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
    Host.Sandbox.resolve ~sw ~flag:Host.Sandbox.Mode.Danger_full_access ~stdenv
      ~env:(Host.Env.get process_env)
      ~project_root:(Host.Config.project_root config) ~workspace ()
    |> get_or_fail Host.Sandbox.Resolve_error.pp
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
    ~finally:(fun () -> ignore (Host.Run.close run : _ result))
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
      let close_ok = Result.is_ok (Host.Run.close run) in
      let child_cancelled =
        match Host.Jobs.list (Host.Run.jobs run) with
        | [ record ] -> (
            match Protocol.Subagent_run.status record with
            | Protocol.Subagent_run.Status.Cancelled _ -> true
            | Protocol.Subagent_run.Status.Queued
            | Protocol.Subagent_run.Status.Running _
            | Protocol.Subagent_run.Status.Blocked _
            | Protocol.Subagent_run.Status.Completed _
            | Protocol.Subagent_run.Status.Failed _ ->
                false)
        | [] | _ :: _ :: _ -> false
      in
      Printf.printf "run close: %b\n" close_ok;
      Printf.printf "running child cancelled: %b\n" child_cancelled;
      [%expect
        {|
        turn-root-first
        run close: true
        running child cancelled: true|}])

let%expect_test
    "cancelling a stalled child settles once and releases its capacity" =
  Project.with_temp "cancel-settlement" @@ fun project ->
  Project.write_scratch project "config/spice/config.json"
    {|{"run":{"subagent_max_concurrent":1}}|};
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
    Host.Sandbox.resolve ~sw ~flag:Host.Sandbox.Mode.Danger_full_access ~stdenv
      ~env:(Host.Env.get process_env)
      ~project_root:(Host.Config.project_root config) ~workspace ()
    |> get_or_fail Host.Sandbox.Resolve_error.pp
  in
  let plan =
    Host.Run.plan ~workspace ~sandbox
      ~permission:(Host.Config.permission_posture config)
      ()
    |> get_or_fail Host.Sandbox.Gate_error.pp
  in
  let store = Host.Session.store ~stdenv host in
  let parent = Session.Id.of_string "session-cancel-settlement" in
  let run =
    Host.Run.start ~sw ~stdenv host plan ~store ~session:parent
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ()
    |> get_or_fail Host.Host.Error.pp
  in
  Fun.protect
    ~finally:(fun () -> ignore (Host.Run.close run : _ result))
    (fun () ->
      let model =
        Host.Models.for_select (Host.Host.catalog host) "openai/gpt-5.5"
        |> get_or_fail Host.Host.Error.pp
      in
      let child_started, resolve_child_started = Eio.Promise.create () in
      let client = cancellation_client ~child_started:resolve_child_started in
      let runner =
        Host.Run.runner run ~mode:Protocol.Mode.Build ~model ~client
        |> get_or_fail Host.Host.Error.pp
      in
      let created_at =
        Eio.Time.now (Eio.Stdenv.clock stdenv)
        |> Session.Time.of_unix_seconds_float
      in
      Host.Session.create ~store ~id:parent ~cwd:(Host.Run.cwd run) ~created_at
        ()
      |> get_or_fail Protocol.Error.pp
      |> ignore;
      let jobs = Host.Run.jobs run in
      let settled = ref [] in
      Host.Jobs.subscribe jobs (function
        | Host.Jobs.Settled record -> settled := record :: !settled
        | Host.Jobs.Started _ | Host.Jobs.Progress _ | Host.Jobs.Blocked _
        | Host.Jobs.Asked _ | Host.Jobs.Resumed _ -> ());
      let spawn task call_id =
        let request =
          Protocol.Subagent.Spawn.make ~role:Protocol.Subagent.Role.Explore
            ~task ()
          |> Result.get_ok
        in
        Host.Jobs.spawn jobs ~parent
          ~parent_turn:(Session.Turn.Id.of_string "turn-parent")
          ~parent_call_id:call_id ~spawn:request ~depth:1
          {
            Host.Jobs.runner = (fun _ ~notices:_ -> Ok runner);
            prompt = task;
            title = task;
            cwd = Host.Run.cwd run;
          }
      in
      let child = spawn "first child stalls" "first" |> Result.get_ok in
      let clock = Eio.Stdenv.clock stdenv in
      Eio.Time.with_timeout_exn clock 5. (fun () ->
          Eio.Promise.await child_started);
      let first_cancel, resolve_first_cancel = Eio.Promise.create () in
      let second_cancel, resolve_second_cancel = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          resolve_once resolve_first_cancel
            (Host.Jobs.cancel jobs ~caller:parent child));
      Eio.Fiber.fork ~sw (fun () ->
          resolve_once resolve_second_cancel
            (Host.Jobs.cancel jobs ~caller:parent child));
      let first_result, second_result =
        Eio.Time.with_timeout_exn clock 5. (fun () ->
            (Eio.Promise.await first_cancel, Eio.Promise.await second_cancel))
      in
      let cancelled_record, cancelled_outcome = Result.get_ok first_result in
      let concurrent_record, concurrent_outcome = Result.get_ok second_result in
      let concurrent_agrees =
        Protocol.Subagent_run.equal cancelled_record concurrent_record
        && is_cancelled concurrent_outcome
      in
      let repeated_record, repeated_outcome =
        Host.Jobs.cancel jobs ~caller:parent child |> Result.get_ok
      in
      let repeat_agrees =
        Protocol.Subagent_run.equal cancelled_record repeated_record
        && is_cancelled repeated_outcome
      in
      let waited_record, waited_outcome =
        Host.Jobs.wait ~cancelled:(fun () -> true) jobs ~caller:parent child
        |> Result.get_ok
      in
      let wait_agrees =
        Protocol.Subagent_run.equal cancelled_record waited_record
        && is_cancelled cancelled_outcome
        && is_cancelled waited_outcome
      in
      let list_agrees =
        Host.Jobs.list jobs
        |> List.find_opt (fun record ->
            Session.Id.equal child (Protocol.Subagent_run.child record))
        |> Option.fold ~none:false ~some:(fun record ->
            Protocol.Subagent_run.equal cancelled_record record)
      in
      let recovered =
        Host.Jobs.create ~sw ~stdenv ~store ~parent ~max_concurrent:1
          ~max_depth:1 ~max_exchanges:1
      in
      let recovered_record, recovered_outcome =
        Host.Jobs.wait recovered ~caller:parent child |> Result.get_ok
      in
      let durable_agrees =
        Protocol.Subagent_run.equal cancelled_record recovered_record
        && is_cancelled recovered_outcome
      in
      let child_settlements =
        List.filter
          (fun record ->
            Session.Id.equal child (Protocol.Subagent_run.child record))
          !settled
        |> List.length
      in
      Printf.printf "cancelled: %b\n" (is_cancelled cancelled_outcome);
      Printf.printf "concurrent cancel agrees: %b\n" concurrent_agrees;
      Printf.printf "repeat cancel agrees: %b\n" repeat_agrees;
      Printf.printf "wait agrees: %b\n" wait_agrees;
      Printf.printf "list agrees: %b\n" list_agrees;
      Printf.printf "durable recovery agrees: %b\n" durable_agrees;
      Printf.printf "child settlements: %d\n" child_settlements;
      let second = spawn "second child settles" "second" |> Result.get_ok in
      let second_record, _ =
        Eio.Time.with_timeout_exn clock 5. (fun () ->
            Host.Jobs.wait jobs ~caller:parent second)
        |> Result.get_ok
      in
      Printf.printf "settlements: %d\n" (List.length !settled);
      print_endline
        (Protocol.Subagent_run.Status.to_string
           (Protocol.Subagent_run.status second_record));
      [%expect
        {|
        cancelled: true
        concurrent cancel agrees: true
        repeat cancel agrees: true
        wait agrees: true
        list agrees: true
        durable recovery agrees: true
        child settlements: 1
        settlements: 2
        completed|}])

let%expect_test "closing a live session interrupts and joins its blocked turn" =
  Project.with_temp "live-close" @@ fun project ->
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
    Host.Sandbox.resolve ~sw ~flag:Host.Sandbox.Mode.Danger_full_access
      ~stdenv ~env:(Host.Env.get process_env)
      ~project_root:(Host.Config.project_root config) ~workspace ()
    |> get_or_fail Host.Sandbox.Resolve_error.pp
  in
  let plan =
    Host.Run.plan ~workspace ~sandbox
      ~permission:(Host.Config.permission_posture config)
      ()
    |> get_or_fail Host.Sandbox.Gate_error.pp
  in
  let store = Host.Session.store ~stdenv host in
  let session = Session.Id.of_string "session-live-close" in
  let run =
    Host.Run.start ~sw ~stdenv host plan ~store ~session
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ()
    |> get_or_fail Host.Host.Error.pp
  in
  Fun.protect
    ~finally:(fun () -> ignore (Host.Run.close run : _ result))
    (fun () ->
      let model =
        Host.Models.for_select (Host.Host.catalog host) "openai/gpt-5.5"
        |> get_or_fail Host.Host.Error.pp
      in
      let started, resolve_started = Eio.Promise.create () in
      let client = blocked_client ~started:resolve_started in
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
      let settlements = ref [] in
      Host.Live.on_settled live (fun result -> settlements := result :: !settlements);
      Host.Live.submit live
        (Protocol.Command.Start (make_start "turn-live-close" "block forever"));
      let clock = Eio.Stdenv.clock stdenv in
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
      Eio.Time.with_timeout_exn clock 2. (fun () -> Host.Live.close live);
      Host.Live.close live;
      let interrupted =
        match !settlements with
        | [ Ok (_, Protocol.Outcome.Finished { outcome; _ }) ] -> (
            match outcome with
            | Session.Turn.Outcome.Interrupted { cancelled = true; _ } -> true
            | Session.Turn.Outcome.Completed | Session.Turn.Outcome.Step_limit
            | Session.Turn.Outcome.Interrupted { cancelled = false; _ }
            | Session.Turn.Outcome.Failed _ ->
                false)
        | [ Ok (_, Protocol.Outcome.Waiting _) ] | [ Error _ ] | [] | _ :: _ :: _
          ->
            false
      in
      Printf.printf "settlements: %d\n" (List.length !settlements);
      Printf.printf "interrupted: %b\n" interrupted;
      Printf.printf "pending: %b\n" (Host.Live.is_pending live);
      [%expect
        {|
        settlements: 1
        interrupted: true
        pending: false|}])
