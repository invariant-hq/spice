(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

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

let truncate_bytes ~max s =
  if String.length s <= max then s else String.sub s 0 max

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
  ^ "). It runs detached: its result will arrive as a notice. Call \
     wait_subagents with this session id when your next step needs the result."

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
let mutations_recorder ~stdenv ~store ~workspace_root =
  let fs = Eio.Stdenv.fs stdenv in
  let store_root = Spice_session_store.root store |> Spice_path.Abs.to_string in
  let run_git argv =
    match
      Eio.Process.parse_out
        ~stderr:(Eio.Flow.buffer_sink (Buffer.create 256))
        (Eio.Stdenv.process_mgr stdenv)
        Eio.Buf_read.take_all argv
    with
    | output -> Ok output
    | exception exn -> Error (Printexc.to_string exn)
  in
  Mutations.recorder
    ~log:(Mutations.Log.make ~fs ~root:store_root)
    ?checkpoint:
      (Mutations.Backend.git_tree ~fs ~run:run_git ~data_root:store_root
         ~workspace_root ())
    ~workspace_root ()

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
  | Ok () ->
      (* An enforcing workspace-write sandbox bounds a command's and a
         workspace edit's blast radius, so the posture credits it here — where
         both facts meet — rather than prompting for operations the sandbox
         already contains. *)
      let permission =
        Permission.Run.with_sandbox_backing
          ~sandbox_backed:(Sandbox.enforces_workspace_write sandbox)
          permission
      in
      Ok { Plan.workspace; sandbox; permission }

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
  add_session_rule : Spice_permission.Policy.Rule.t -> unit;
}

let start ~sw ~stdenv host plan ~store ~session ~http ~fetch_https ?max_steps
    ?skills:preloaded_skills ?cwd_override () =
  let config = Host.config host in
  let workspace = Plan.workspace plan in
  let sandbox = Plan.sandbox plan in
  let permission = Plan.permission plan in
  (* Reviewer "always allow" grants for this run. They live here, not in the
     session document, so a session-scoped grant is deliberately per-run: a
     later [resume] is a fresh process that re-reads only the durable config.
     [runner_for] folds the current list into the posture on every turn
     derivation, so a grant added mid-turn decides the next tool call. *)
  let session_rules = ref [] in
  let* context = Context.load ~stdenv config in
  let skills =
    match preloaded_skills with
    | Some skills -> skills
    | None -> Skills.load ~stdenv ~builtins:Spice_prompts.Skills.all config
  in
  let cwd_eio = Context.eio_cwd ~stdenv ?override:cwd_override context in
  let notices = Notice_queue.create () in
  let workspace_root = workspace_root_string workspace in
  let producers =
    Producers.start ~sw ~stdenv host ~inbox:notices ~workspace ~cwd:cwd_eio
      ~root:workspace_root ()
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
  let mutations = mutations_recorder ~stdenv ~store ~workspace_root in
  let jobs =
    Jobs.create ~sw ~stdenv ~store
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
  Jobs.subscribe jobs (function
    | Jobs.Settled run -> (
        match Jobs.asked jobs (Spice_protocol.Subagent_run.child run) with
        | Some message -> Notice_queue.publish notices (ask_notice run message)
        | None -> Notice_queue.publish notices (settle_notice run))
    | Jobs.Started _ | Jobs.Progress _ | Jobs.Blocked _ | Jobs.Asked _
    | Jobs.Resumed _ ->
        ());
  (* One wait result section per named run, in request order; a child that
     did not complete reads as such rather than failing the whole wait. An
     unknown run id fails the call before any blocking. *)
  let wait_result ~cancelled run =
    match Jobs.wait ~cancelled jobs run with
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
  let wait_runs ~cancelled request =
    let rec collect acc = function
      | [] -> Ok (String.concat "\n\n" (List.rev acc))
      | run :: rest -> (
          match wait_result ~cancelled run with
          | Error _ as error -> error
          | Ok section -> collect (section :: acc) rest)
    in
    collect [] (Spice_protocol.Subagent.Wait.Request.runs request)
  in
  let cancel_run request =
    let run = Spice_protocol.Subagent.Cancel.Request.run request in
    match Jobs.cancel jobs run with
    | Error _ as error -> error
    | Ok () -> (
        match Jobs.wait jobs run with
        | Error _ as error -> error
        | Ok (record, _) ->
            Ok
              ("subagent "
              ^ Spice_protocol.Subagent.Role.to_string
                  (Spice_protocol.Subagent_run.role record)
              ^ " cancelled (session "
              ^ Spice_session.Id.to_string
                  (Spice_protocol.Subagent_run.child record)
              ^ ")."))
  in
  let message_run request =
    match
      Jobs.message ~origin:`Model jobs
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
    |> Session.with_terminal_observed (fun ~observe:_ _ -> Jobs.drain jobs)
    |> Mutations.hook mutations
  in
  (* The per-turn derivation: everything the turn's contract — mode, model,
     credentialed client — conditions is built here, over the assembled
     workspace, so a frontend re-binding at each turn pays only pure assembly
     and no producer restart. *)
  let runner_for ~mode ~model ~client =
    let permission =
      Permission.Run.with_session_rules !session_rules permission
    in
    let* prelude =
      Context.extend_prelude context (Spice_protocol.Mode.prelude_messages mode)
      |> Result.map_error (fun error -> Host.Error.Instructions error)
    in
    let tools =
      Toolset.make ~sw ~stdenv host ?model:(Some model) ~workspace ~sandbox
        ~skills ~cwd:cwd_eio ~http ~fetch_https ?anchors
        ~dune:(Producers.dune producers)
        ~project_source:(Producers.project_source producers)
        ~merlin_program:(Producers.merlin_program producers)
        ()
      |> Spice_protocol.Contract.filter_tools
           (Spice_protocol.Mode.contract mode)
    in
    let policy =
      Spice_protocol.Contract.policy
        (Spice_protocol.Mode.contract mode)
        ~configured:(Permission.Run.policy permission)
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
      Spice_session.Run.Config.make ~tools ~host_tools ~policy ~denial_message
        ~prelude ?max_steps ()
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
       contract's [client] for its whole run. *)
    let child_run_config role =
      let contract = Spice_protocol.Subagent.Role.contract role in
      let parent_policy =
        Spice_protocol.Contract.policy
          (Spice_protocol.Mode.contract mode)
          ~configured:(Permission.Run.policy permission)
      in
      let* prelude =
        Context.extend_prelude context
          (Spice_protocol.Subagent.Role.prelude_messages role)
        |> Result.map_error (fun error -> Host.Error.Instructions error)
      in
      let child_tools = Spice_protocol.Contract.filter_tools contract tools in
      let child_policy =
        Spice_protocol.Contract.policy contract ~configured:parent_policy
      in
      let child_max_steps = Config.Runtime.max_steps (Config.runtime config) in
      (* A child's only host tool is [message_parent]: it can ask, but it
         cannot spawn further children or touch the parent's workflow state. *)
      Ok
        (Spice_session.Run.Config.make ~tools:child_tools ~policy:child_policy
           ~host_tools:
             [
               Spice_protocol.Call.Kind.tool
                 Spice_protocol.Call.Kind.Subagent_message_parent;
             ]
           ~denial_message ~prelude ?max_steps:child_max_steps ())
    in
    let spawn_child spawn ~parent =
      let parent_session = Spice_session_store.Document.session parent in
      let role = Spice_protocol.Subagent.Spawn.role spawn in
      let parent_call_id =
        match Spice_session.Run.phase parent_session with
        | Spice_session.Run.Phase.Waiting
            (Spice_session.Waiting.Host_tool host_tool) ->
            Spice_llm.Tool.Call.id host_tool.Spice_session.Waiting.call
        | Spice_session.Run.Phase.Waiting _ | Spice_session.Run.Phase.Idle
        | Spice_session.Run.Phase.Active ->
            ""
      in
      match
        Spice_session.State.active_turn (Spice_session.state parent_session)
      with
      | None -> Error "subagent spawn has no active parent turn"
      | Some parent_turn -> (
          let child_spec =
            {
              Jobs.runner =
                (fun (_ : Spice_session.Id.t) ~notices ->
                  match child_run_config role with
                  | Error error -> Error (Host.Error.message error)
                  | Ok child_config ->
                      Ok
                        (Runner.make ~store ~client
                           ~model:(Spice_provider.Model.llm model)
                           ~mode:None ~run:child_config ~host_tool:Handler.child
                           ~hooks:
                             (Session.with_notices
                                ~before_request:(fun () -> ())
                                notices Session.no_hooks)
                           ()));
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
              ~parent_turn ~parent_call_id ~spawn ~depth:1 child_spec
          with
          | Error _ as error -> error
          | Ok child -> Ok (launched_subagent_text ~child spawn))
    in
    let handler =
      Handler.defaults ~fs ~root
        ~now:(fun () -> now stdenv)
        ~mode ~spawn:spawn_child ~wait:wait_runs ~cancel:cancel_run
        ~message:message_run
    in
    Ok
      (Runner.make ~store ~client
         ~model:(Spice_provider.Model.llm model)
         ~mode:(Some mode) ~run:run_config ~host_tool:handler ~resolve_plan
         ?compaction ~hooks ())
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
      add_session_rule =
        (fun rule -> session_rules := !session_rules @ [ rule ]);
    }

let stop t = Producers.stop t.producers
let jobs t = t.jobs
let runner t ~mode ~model ~client = t.runner_for ~mode ~model ~client
let add_session_rule t rule = t.add_session_rule rule
let workspace t = t.workspace
let cwd t = t.cwd
let context t = t.context
let notices t = t.notices
