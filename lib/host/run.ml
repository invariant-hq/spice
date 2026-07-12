(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

let log_src = Logs.Src.create "spice.host.run"
module Log = (val Logs.src_log log_src : Logs.LOG)

let now stdenv =
  Eio.Time.now (Eio.Stdenv.clock stdenv)
  |> Spice_session.Time.of_unix_seconds_float

(* Child session title: the role and a whitespace-collapsed, byte-bounded task
   summary. The task is non-empty by the spawn invariant, so the title is too. *)
let collapse_whitespace s =
  let b = Buffer.create (String.length s) in
  let pending_space = ref false in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' ->
          if Buffer.length b > 0 then pending_space := true
      | _ ->
          if !pending_space then Buffer.add_char b ' ';
          pending_space := false;
          Buffer.add_char b c)
    s;
  Buffer.contents b

let utf8_boundary text index =
  let rec loop index =
    if index <= 0 then 0
    else
      let code = Char.code text.[index] in
      if code land 0b1100_0000 = 0b1000_0000 then loop (index - 1) else index
  in
  loop (min index (String.length text))

let truncate_bytes ~max s =
  if String.length s <= max then s
  else String.sub s 0 (utf8_boundary s max)

let child_session_title spawn =
  let role =
    Spice_protocol.Subagent.Role.to_string
      (Spice_protocol.Subagent.Spawn.role spawn)
  in
  let task =
    truncate_bytes ~max:80
      (collapse_whitespace (Spice_protocol.Subagent.Spawn.task spawn))
  in
  "subagent " ^ role ^ ": " ^ task

let child_prompt spawn =
  let role =
    Spice_protocol.Subagent.Role.to_string
      (Spice_protocol.Subagent.Spawn.role spawn)
  in
  let task = Spice_protocol.Subagent.Spawn.task spawn in
  let scope_lines =
    match Spice_protocol.Subagent.Spawn.scope spawn with
    | [] -> []
    | scope -> "" :: "Scope:" :: List.map (fun entry -> "- " ^ entry) scope
  in
  let expected_lines =
    match Spice_protocol.Subagent.Spawn.expected_output spawn with
    | None -> []
    | Some expected -> [ ""; "Expected output:"; expected ]
  in
  String.concat "\n"
    ([ "Role: " ^ role; ""; "Task:"; task ] @ scope_lines @ expected_lines)

let completed_subagent_text run summary =
  let child =
    Spice_session.Id.to_string (Spice_protocol.Subagent_run.child run)
  in
  let role =
    Spice_protocol.Subagent.Role.to_string
      (Spice_protocol.Subagent_run.role run)
  in
  "subagent " ^ role ^ " completed (session " ^ child ^ ").\n\n" ^ summary

let errored_subagent_text run message =
  let child =
    Spice_session.Id.to_string (Spice_protocol.Subagent_run.child run)
  in
  let role =
    Spice_protocol.Subagent.Role.to_string
      (Spice_protocol.Subagent_run.role run)
  in
  "subagent " ^ role ^ " did not complete (session " ^ child ^ ").\n\n"
  ^ message

let launched_subagent_text ~child spawn =
  let role =
    Spice_protocol.Subagent.Role.to_string
      (Spice_protocol.Subagent.Spawn.role spawn)
  in
  "subagent " ^ role ^ " launched (session "
  ^ Spice_session.Id.to_string child
  ^ "). It runs detached. Call wait_subagents with this session id when your \
     next step needs the result; settlements reached while this host run stays \
     active also arrive as notices."

let child_interrupt_message ~reason ~cancelled =
  match reason with
  | Some reason -> "child session interrupted: " ^ reason
  | None when cancelled -> "child session cancelled"
  | None -> "child session interrupted"

let workspace_root_string workspace =
  match Spice_workspace.roots workspace with
  | root :: _ -> Spice_path.Abs.to_string (Spice_workspace.Root.dir root)
  | [] ->
      Spice_path.Abs.to_string
        (Spice_workspace.Path.abs (Spice_workspace.cwd workspace))

(* The ledger lives beside the session documents; the checkpoint backend is
   present only for git workspaces. *)
let mutations_recorder ~stdenv ~store ~sandbox ~trusted ~workspace_root =
  let fs = Eio.Stdenv.fs stdenv in
  let store_root = Spice_session_store.root store |> Spice_path.Abs.to_string in
  let run_git argv =
    match argv with
    | [] -> Error "git process argv is empty"
    | program :: args -> (
        let argv = Spice_sandbox.Argv.make ~program args in
        let cwd = Spice_path.Abs.of_string_exn workspace_root in
        match Spice_sandbox.spawn sandbox ~cwd ~argv with
        | Error error -> Error (Spice_sandbox.Error.message error)
        | Ok spawn -> (
            let argv =
              Spice_sandbox.Spawn.argv spawn |> Spice_sandbox.Argv.to_list
            in
            let env =
              Spice_sandbox.Spawn.env spawn
              |> List.map (fun (name, value) -> name ^ "=" ^ value)
              |> Array.of_list
            in
            match
              Eio.Process.parse_out ~env
                ~cwd:(Eio.Path.( / ) (Eio.Stdenv.fs stdenv) workspace_root)
                ~stderr:(Eio.Flow.buffer_sink (Buffer.create 256))
                (Eio.Stdenv.process_mgr stdenv)
                Eio.Buf_read.take_all argv
            with
            | output -> Ok output
            | exception exn -> Error (Printexc.to_string exn)))
  in
  let workspace_root, checkpoint =
    if not trusted then (workspace_root, None)
    else
      let workspace_root =
        match
          run_git
            [ "git"; "-C"; workspace_root; "rev-parse"; "--show-toplevel" ]
        with
        | Ok root when not (String.is_empty (String.trim root)) ->
            String.trim root
        | Ok _ | Error _ -> workspace_root
      in
      ( workspace_root,
        Mutations.Backend.git_tree ~fs ~run:run_git ~data_root:store_root
          ~workspace_root () )
  in
  let shell_changes () =
    match checkpoint with
    | None -> fun () -> []
    | Some backend -> (
        match backend.Mutations.Backend.capture () with
        | Error message ->
            Log.warn (fun m ->
                m "shell attribution start checkpoint failed: %s" message);
            fun () -> []
        | Ok before -> (
            fun () ->
              match backend.Mutations.Backend.capture () with
              | Error message ->
                  Log.warn (fun m ->
                      m "shell attribution end checkpoint failed: %s" message);
                  []
              | Ok after -> (
                  match
                    backend.Mutations.Backend.paths
                      ~from_:before.Mutations.Backend.reference
                      ~to_:after.Mutations.Backend.reference
                  with
                  | Ok paths -> List.map fst paths
                  | Error message ->
                      Log.warn (fun m ->
                          m "shell attribution checkpoint diff failed: %s"
                            message);
                      [])))
  in
  ( Mutations.recorder
      ~log:(Mutations.Log.make ~fs ~root:store_root)
      ?checkpoint
      ~workspace_root (),
    shell_changes )

(* Planning *)

module Plan = struct
  type t = {
    workspace : Spice_workspace.t;
    sandbox : Sandbox.Effective.t;
    permission : Config.Source.t Permission.Run.t;
  }

  let workspace t = t.workspace
  let sandbox t = t.sandbox
  let permission t = t.permission
end

let plan ~workspace ~sandbox ~permission () =
  (* The gate is the fail-closed step: an unenforceable confined run fails here,
     before [start] loads any credential. On success the posture is readable. *)
  match Sandbox.gate sandbox with
  | Error _ as error -> error
  | Ok () -> Ok { Plan.workspace; sandbox; permission }

(* The run *)

type t = {
  workspace : Spice_workspace.t;
  cwd : Spice_path.Abs.t;
  context : Context.t;
  notices : Notice_queue.t;
  producers : Producers.t;
  jobs : Jobs.t;
  runner_for :
    mode:Spice_protocol.Mode.t ->
    model:Spice_provider.Model.t ->
    client:Spice_llm.Client.t ->
    (Runner.t, Host.Error.t) result;
}

let start ~sw ~stdenv host plan ~store ~session ~http ~fetch_https ?max_steps
    ?skills:preloaded_skills ?cwd_override () =
  let config = Host.config host in
  let config_files = Config.files config in
  let user_permission_path =
    Config.Config_file.user config_files |> Spice_path.Abs.to_string
  in
  let save_user_permission_rules rules =
    match
      Config.Config_file.add_user_permission_rules ~stdenv config_files rules
    with
    | Ok () -> Ok user_permission_path
    | Error error ->
        Error
          (Spice_protocol.Error.Permission_rule_save_failed
             {
               path = user_permission_path;
               message = Config.Error.message error;
               hints = Config.Error.hints error;
             })
  in
  let workspace = Plan.workspace plan in
  let sandbox = Plan.sandbox plan in
  let permission = Plan.permission plan in
  let* context = Context.load ~stdenv config in
  let skills =
    match preloaded_skills with
    | Some skills -> skills
    | None -> Skills.load ~stdenv ~builtins:Spice_prompts.Skills.all config
  in
  let cwd_eio = Context.eio_cwd ~stdenv ?override:cwd_override context in
  let notices = Notice_queue.create () in
  let workspace_root = workspace_root_string workspace in
  let mutation_attribution =
    Mutation_attribution.create
      ~publish:(Watchers.Fswatch.publish notices ~root:workspace_root)
      ()
  in
  let producers =
    Producers.start ~sw ~stdenv host ~inbox:notices
      ~on_fswatch:(Mutation_attribution.observe mutation_attribution)
      ~workspace ~cwd:cwd_eio ~sandbox ~root:workspace_root ()
  in
  let denial_message =
    Permission.Run.denial_message ~source:Config.Source.kind_string permission
  in
  (* Anchored edits are flag-gated: ONE resolver per run, seeded from the
     session id so scripted transcripts are stable. Anchors span turns — a
     read in one turn mints anchors a later turn's edit resolves — so the
     resolver must not be recreated per derivation. *)
  let anchors =
    if Config.Tools.anchored_edits (Config.tools config) then
      Some
        (Spice_tools.Anchor_tracker.resolver
           (Spice_tools.Anchor_tracker.create
              ~seed:(Spice_session.Id.to_string session)
              ()))
    else None
  in
  let fs = Eio.Stdenv.fs stdenv in
  let root = Spice_session_store.root store |> Spice_path.Abs.to_string in
  let mutations, shell_changes =
    mutations_recorder ~stdenv ~store
      ~sandbox:(Sandbox.Effective.sandbox sandbox)
      ~trusted:(Trust.is_trusted (Config.workspace_trust config))
      ~workspace_root
  in
  let jobs =
    Jobs.create ~sw ~stdenv ~store ~parent:session
      ~max_concurrent:
        (Config.Runtime.subagent_max_concurrent (Config.runtime config))
      ~max_depth:(Config.Runtime.subagent_max_depth (Config.runtime config))
      ~max_exchanges:
        (Config.Runtime.subagent_max_exchanges (Config.runtime config))
  in
  (* Settlement is pushed, not polled: every settled run publishes a notice
     the model sees at its next request, keyed per run so one child's settle
     never evicts another's. *)
  let settle_notice run =
    let child = Spice_protocol.Subagent_run.child run in
    let role =
      Spice_protocol.Subagent.Role.to_string
        (Spice_protocol.Subagent_run.role run)
    in
    let severity, headline, body =
      match Spice_protocol.Subagent_run.status run with
      | Spice_protocol.Subagent_run.Status.Completed { summary; _ } ->
          (Spice_protocol.Notice.Severity.Info, "finished", Some summary)
      | Spice_protocol.Subagent_run.Status.Blocked { blocker; _ } ->
          (Spice_protocol.Notice.Severity.Warning, "blocked", Some blocker)
      | Spice_protocol.Subagent_run.Status.Cancelled _ ->
          (Spice_protocol.Notice.Severity.Warning, "cancelled", None)
      | Spice_protocol.Subagent_run.Status.Failed { message; _ } ->
          (Spice_protocol.Notice.Severity.Error, "failed", Some message)
      | Spice_protocol.Subagent_run.Status.Queued
      | Spice_protocol.Subagent_run.Status.Running _ ->
          (Spice_protocol.Notice.Severity.Info, "settled", None)
    in
    let title =
      "subagent " ^ role ^ " " ^ headline ^ " (session "
      ^ Spice_session.Id.to_string child
      ^ ")"
    in
    Spice_protocol.Notice.make ~source:"subagents" ~severity ~title ?body
      ~key:("subagent-run:" ^ Spice_session.Id.to_string child)
      ()
  in
  (* An ask notice replaces the generic blocked one: the question itself plus
     the must-address reminder, so the parent model cannot drop it. *)
  let ask_notice run message =
    let child = Spice_protocol.Subagent_run.child run in
    let role =
      Spice_protocol.Subagent.Role.to_string
        (Spice_protocol.Subagent_run.role run)
    in
    Spice_protocol.Notice.make ~source:"subagents"
      ~severity:Spice_protocol.Notice.Severity.Warning
      ~title:
        ("subagent " ^ role ^ " asked (session "
        ^ Spice_session.Id.to_string child
        ^ ")")
      ~body:
        (message ^ "\n\nReply with message_subagent (run "
        ^ Spice_session.Id.to_string child
        ^ "); the subagent is parked until you answer. Address this before \
           continuing other work.")
      ~key:("subagent-run:" ^ Spice_session.Id.to_string child)
      ()
  in
  let publish_parent_notice run notice =
    let parent = Spice_protocol.Subagent_run.parent run in
    if Spice_session.Id.equal parent session then
      Notice_queue.publish notices notice
    else
      match Jobs.publish_notice jobs parent notice with
      | Ok () -> ()
      | Error message ->
          Log.warn (fun m ->
              m "could not deliver subagent settlement to parent %a: %s"
                Spice_session.Id.pp parent message)
  in
  Jobs.subscribe jobs (function
    | Jobs.Settled run -> (
        match Jobs.asked jobs (Spice_protocol.Subagent_run.child run) with
        | Some message -> publish_parent_notice run (ask_notice run message)
        | None -> publish_parent_notice run (settle_notice run))
    | Jobs.Started _ | Jobs.Progress _ | Jobs.Blocked _ | Jobs.Asked _
    | Jobs.Resumed _ ->
        ());
  (* One wait result section per named run, in request order; a child that
     did not complete reads as such rather than failing the whole wait. An
     unknown run id fails the call before any blocking. *)
  let wait_result ~caller ~cancelled run =
    match Jobs.wait ~cancelled jobs ~caller run with
    | Error _ as error -> error
    | Ok (record, Jobs.Summary summary) ->
        Ok (completed_subagent_text record summary)
    | Ok (record, Jobs.Blocked_on { blocker }) ->
        Ok (errored_subagent_text record blocker)
    | Ok (record, Jobs.Interrupted { reason; cancelled }) ->
        Ok
          (errored_subagent_text record
             (child_interrupt_message ~reason ~cancelled))
    | Ok (record, Jobs.Failed_with message) ->
        Ok (errored_subagent_text record message)
    | Ok (record, Jobs.Wait_interrupted) ->
        Ok
          ("wait interrupted before subagent "
          ^ Spice_protocol.Subagent.Role.to_string
              (Spice_protocol.Subagent_run.role record)
          ^ " settled (session "
          ^ Spice_session.Id.to_string
              (Spice_protocol.Subagent_run.child record)
          ^ "); it is still running.")
  in
  let wait_runs ~caller ~cancelled request =
    let rec collect acc = function
      | [] -> Ok (String.concat "\n\n" (List.rev acc))
      | run :: rest -> (
          match wait_result ~caller ~cancelled run with
          | Error _ as error -> error
          | Ok section -> collect (section :: acc) rest)
    in
    collect [] (Spice_protocol.Subagent.Wait.Request.runs request)
  in
  let cancel_run ~caller request =
    let run = Spice_protocol.Subagent.Cancel.Request.run request in
    match Jobs.cancel jobs ~caller run with
    | Error _ as error -> error
    | Ok (record, _) ->
        Ok
          ("subagent "
          ^ Spice_protocol.Subagent.Role.to_string
              (Spice_protocol.Subagent_run.role record)
          ^ " cancelled (session "
          ^ Spice_session.Id.to_string
              (Spice_protocol.Subagent_run.child record)
          ^ ").")
  in
  let message_run ~caller ~runner request =
    match
      Jobs.message ~runner ~origin:`Model jobs
        ~caller
        (Spice_protocol.Subagent.Message.Request.run request)
        (Spice_protocol.Subagent.Message.Request.message request)
    with
    | Error _ as error -> error
    | Ok `Delivered ->
        Ok
          ("message delivered to subagent (session "
          ^ Spice_session.Id.to_string
              (Spice_protocol.Subagent.Message.Request.run request)
          ^ "); it will see it at its next step. If it finishes without acting \
             on it, message again to resume it.")
    | Ok `Resumed ->
        Ok
          ("subagent resumed with your message (session "
          ^ Spice_session.Id.to_string
              (Spice_protocol.Subagent.Message.Request.run request)
          ^ "); its result will arrive as a notice.")
  in
  (* The host-side plan resolution the [Resolve_plan] command runs: the durable
     transition and the model-visible wording live in [Artifacts.Plan.resolve].
     A no-longer-proposable plan (a superseded proposal) surfaces as
     [Artifacts.Error.Conflict], reported to the client as an execution error so
     a stale dialog fails loudly rather than wedging the turn. *)
  let resolve_plan ~decision proposal =
    Artifacts.Plan.resolve ~fs ~root ~session ~now:(now stdenv) ~decision
      proposal
    |> Result.map_error Artifacts.Error.to_protocol_error
  in
  let hooks =
    Session.no_hooks
    |> Session.with_observe (Goal_run.budget_watch ~fs ~root ~session ~notices)
    |> Session.with_notices
         ~before_request:(Producers.before_request producers)
         notices
    |> Mutations.hook mutations
    |> Mutation_attribution.hook ~shell_changes mutation_attribution
    (* Each saved step re-evaluates the workspace-tooling latch, so a turn
       that scaffolds a dune project (any tool — a shell [dune init] included,
       its result is a saved step too) engages describe/Merlin/watch for its
       own later steps and heals the frontend feeds. Latching: a no-op once
       engaged. *)
    |> Session.with_after_save (fun _document _events ->
        Producers.reprobe producers)
  in
  (* The per-turn derivation: everything the turn's contract — mode, model,
     credentialed client — conditions is built here, over the assembled
     workspace, so a frontend re-binding at each turn pays only pure assembly
     and no producer restart. *)
  let runner_for ~mode ~model ~client =
    let* prelude =
      Context.extend_prelude context (Spice_protocol.Mode.prelude_messages mode)
      |> Result.map_error (fun error -> Host.Error.Instructions error)
    in
    let project_execution =
      Spice_protocol.Mode.equal mode Spice_protocol.Mode.Build
    in
    Producers.set_build_enabled producers project_execution;
    let tools =
      Toolset.make ~sw ~stdenv host ?model:(Some model) ~workspace ~sandbox
        ~skills ~cwd:cwd_eio ~http ~fetch_https ?anchors
        ~dune:(Producers.dune producers)
        ~project_source:(Producers.project_source producers)
        ~merlin_program:(Producers.merlin_program producers)
        ~project_execution
        ()
      |> Spice_protocol.Contract.filter_tools
           (Spice_protocol.Mode.contract mode)
    in
    let policy conversation =
      Spice_protocol.Contract.policy
        (Spice_protocol.Mode.contract mode)
        ~configured:(Permission.Run.policy ~conversation permission)
    in
    (* The mode offer is the ceiling; the goal kind is further conditioned on
       the session's stored goal, read at each derivation so a goal update is
       reflected by the next turn. Catalog absence is UX only — the handler
       rejects a stray update_goal either way — so a load failure just leaves
       the tool out and surfaces on the next artifact operation. *)
    let offers_goal =
      match Artifacts.Goal.load ~fs ~root session with
      | Ok (Some goal) -> Spice_protocol.Goal.may_update goal
      | Ok None | Error _ -> false
    in
    let host_tools =
      Spice_protocol.Mode.host_tools mode
      |> List.filter (fun kind ->
          match (kind : Spice_protocol.Call.Kind.t) with
          | Spice_protocol.Call.Kind.Goal -> offers_goal
          | Spice_protocol.Call.Kind.Question | Spice_protocol.Call.Kind.Plan
          | Spice_protocol.Call.Kind.Todo | Spice_protocol.Call.Kind.Subagent
          | Spice_protocol.Call.Kind.Subagent_wait
          | Spice_protocol.Call.Kind.Subagent_cancel ->
              true
          | Spice_protocol.Call.Kind.Subagent_message -> true
          (* Child-contract only; never offered to a root session. *)
          | Spice_protocol.Call.Kind.Subagent_message_parent -> false)
      |> List.map Spice_protocol.Call.Kind.tool
    in
    let run_config =
      Spice_session_run.Config.make ~tools ~host_tools ~policy
        ~on_review:(Permission.Run.on_review permission)
        ~denial_message ~prelude ?safety_step_cap:max_steps ()
    in
    (* Disabling automatic compaction is the absence of the policy: the
       interpreter performs neither pressure compaction nor overflow recovery
       without one. Manual compaction is unaffected. *)
    let compaction =
      if Config.Runtime.compaction_auto (Config.runtime config) then
        Some (Compactor.Policy.of_model ~prelude model)
      else None
    in
    (* Child-run orchestration: the child config derives from the parent env,
       and the {!Jobs} registry owns minting, the run ledger, the child Live
       attachment, settlement, and process-exit draining. A child binds this
       contract's [client] for each live episode. *)
    let child_run_config role =
      let contract = Spice_protocol.Subagent.Role.contract role in
      let parent_policy conversation =
        Spice_protocol.Contract.policy
          (Spice_protocol.Mode.contract mode)
          ~configured:(Permission.Run.policy ~conversation permission)
      in
      let* prelude =
        Context.extend_prelude context
          (Spice_protocol.Subagent.Role.prelude_messages role)
        |> Result.map_error (fun error -> Host.Error.Instructions error)
      in
      let child_tools = Spice_protocol.Contract.filter_tools contract tools in
      let child_policy conversation =
        Spice_protocol.Contract.policy contract
          ~configured:(parent_policy conversation)
      in
      let child_max_steps = Config.Runtime.max_steps (Config.runtime config) in
      (* Workflow state stays root-only. Collaboration composes recursively:
         every descendant receives the same lifecycle tools and the registry
         applies the shared depth and running-capacity bounds. *)
      Ok
        (Spice_session_run.Config.make ~tools:child_tools ~policy:child_policy
           ~on_review:(Permission.Run.on_review permission)
           ~host_tools:
             [
               Spice_protocol.Call.Kind.tool
                 Spice_protocol.Call.Kind.Subagent;
               Spice_protocol.Call.Kind.tool
                 Spice_protocol.Call.Kind.Subagent_wait;
               Spice_protocol.Call.Kind.tool
                 Spice_protocol.Call.Kind.Subagent_cancel;
               Spice_protocol.Call.Kind.tool
                 Spice_protocol.Call.Kind.Subagent_message;
               Spice_protocol.Call.Kind.tool
                 Spice_protocol.Call.Kind.Subagent_message_parent;
             ]
           ~denial_message ~prelude
           ?safety_step_cap:child_max_steps ())
    in
    let rec child_runner role ~session:child_session ~depth ~notices =
      let* child_config =
        child_run_config role |> Result.map_error Host.Error.message
      in
      let handler =
        Handler.subagent ~mode ~spawn:(spawn_child ~parent_depth:depth)
          ~wait:(wait_runs ~caller:child_session)
          ~cancel:(cancel_run ~caller:child_session)
          ~message:
            (message_run ~caller:child_session ~runner:resume_runner)
      in
      Ok
        (Runner.make ~store ~client ~model:(Spice_provider.Model.llm model)
           ~mode:None ~run:child_config ~save_user_permission_rules
           ~host_tool:handler
           ~hooks:
             (Session.with_notices ~before_request:(fun () -> ()) notices
                Session.no_hooks)
           ())
    and resume_runner run ~notices =
      child_runner (Spice_protocol.Subagent_run.role run)
        ~session:(Spice_protocol.Subagent_run.child run)
        ~depth:(Spice_protocol.Subagent_run.depth run) ~notices
    and spawn_child ~parent_depth spawn ~parent =
      let parent_session = Spice_session_store.Document.session parent in
      let role = Spice_protocol.Subagent.Spawn.role spawn in
      let depth = parent_depth + 1 in
      let parent_call_id =
        match Spice_session.State.phase (Spice_session.state parent_session) with
        | Spice_session.State.Phase.Waiting
            (Spice_session.Waiting.Host_tool host_tool) ->
            Spice_llm.Tool.Call.id host_tool.Spice_session.Waiting.call
        | Spice_session.State.Phase.Waiting _ | Spice_session.State.Phase.Idle
        | Spice_session.State.Phase.Active ->
            ""
      in
      match
        Spice_session.State.active_turn_id (Spice_session.state parent_session)
      with
      | None -> Error "subagent spawn has no active parent turn"
      | Some parent_turn -> (
          let child_spec =
            {
              Jobs.runner =
                (fun child_session ~notices ->
                  child_runner role ~session:child_session ~depth ~notices);
              prompt = child_prompt spawn;
              title = child_session_title spawn;
              cwd =
                Spice_session.Metadata.cwd
                  (Spice_session.metadata parent_session);
            }
          in
          match
            Jobs.spawn jobs
              ~parent:(Spice_session.id parent_session)
              ~parent_turn ~parent_call_id ~spawn ~depth child_spec
          with
          | Error _ as error -> error
          | Ok child -> Ok (launched_subagent_text ~child spawn))
    in
    let handler =
      Handler.defaults ~fs ~root
        ~now:(fun () -> now stdenv)
        ~mode ~spawn:(spawn_child ~parent_depth:0)
        ~wait:(wait_runs ~caller:session) ~cancel:(cancel_run ~caller:session)
        ~message:(message_run ~caller:session ~runner:resume_runner)
    in
    Ok
      (Runner.make ~store ~client
         ~model:(Spice_provider.Model.llm model)
         ~mode:(Some mode) ~run:run_config ~save_user_permission_rules
         ~host_tool:handler ~resolve_plan ?compaction ~hooks ())
  in
  Ok
    {
      workspace;
      cwd = Context.cwd context;
      context;
      notices;
      producers;
      jobs;
      runner_for;
    }

let close t =
  Eio.Cancel.protect (fun () ->
      Fun.protect
        ~finally:(fun () -> Producers.stop t.producers)
        (fun () -> Jobs.close t.jobs))

let jobs t = t.jobs
let runner t ~mode ~model ~client = t.runner_for ~mode ~model ~client
let workspace t = t.workspace
let cwd t = t.cwd
let context t = t.context
let notices t = t.notices
