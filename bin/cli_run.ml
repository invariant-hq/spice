(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Cli_common
open Result.Syntax
module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
module Host_session = Spice_host.Session
module Model_choice = Spice_host.Models.Model_choice
module Models = Spice_host.Models
module Goal = Spice_protocol.Goal
module Goal_run = Spice_host.Goal_run
module Session = Spice_session
module Store = Spice_session_store
module Term = Cmdliner.Term
module Tool_call = Spice_llm.Tool.Call

(* Fresh identifiers and time *)

let fresh_id =
  let counter = ref 0 in
  fun stdenv prefix ->
    incr counter;
    let stamp =
      Eio.Time.now (Eio.Stdenv.clock stdenv)
      |> Int64.bits_of_float |> Int64.to_string
    in
    prefix ^ "_" ^ stamp ^ "_" ^ string_of_int !counter

let fresh_session_id stdenv = Session.Id.of_string (fresh_id stdenv "ses")
let fresh_turn_id stdenv = Session.Turn.Id.of_string (fresh_id stdenv "turn")
let monotonic_now stdenv = Eio.Time.Mono.now (Eio.Stdenv.mono_clock stdenv)

let duration_ms ~started stdenv =
  Mtime.span started (monotonic_now stdenv) |> Mtime.Span.to_float_ns
  |> fun ns -> max 0 (int_of_float (ns /. 1_000_000.))

(* User input *)

let read_prompt = function
  | None -> usage "run requires PROMPT or -"
  | Some "-" ->
      let text = In_channel.input_all stdin |> String.trim in
      if String.is_empty text then usage "stdin prompt must not be empty"
      else Ok text
  | Some text ->
      if String.is_empty text then usage "prompt must not be empty" else Ok text

let read_nonempty_stdin ~empty_message =
  let text = In_channel.input_all stdin |> String.trim in
  if String.is_empty text then usage empty_message else Ok text

let read_answer = function
  | None -> usage "--answer requires TEXT or -"
  | Some "-" ->
      read_nonempty_stdin ~empty_message:"stdin answer must not be empty"
  | Some text ->
      if String.is_empty text then usage "answer must not be empty" else Ok text

let read_deny_message = function
  | None -> Ok None
  | Some "-" ->
      read_nonempty_stdin ~empty_message:"stdin message must not be empty"
      |> Result.map Option.some
  | Some text ->
      if String.is_empty text then usage "message must not be empty"
      else Ok (Some text)

let default_tool_interrupted_reason =
  "host restarted before the tool result was recorded"

let read_tool_interrupted_reason = function
  | None -> Ok default_tool_interrupted_reason
  | Some "-" ->
      read_nonempty_stdin ~empty_message:"stdin reason must not be empty"
  | Some text ->
      if String.is_empty text then usage "reason must not be empty" else Ok text

let validate_max_steps = function
  | None -> Ok ()
  | Some value when value > 0 -> Ok ()
  | Some value ->
      usage ("--max-steps must be positive, got " ^ string_of_int value)

(* Workflow modes *)

let mode_for_new_turn = function
  | None -> Spice_protocol.Mode.default
  | Some mode -> mode

let mode_for_active_turn requested turn =
  let persisted = Spice_protocol.Mode.of_turn turn in
  match requested with
  | None -> Ok persisted
  | Some requested when Spice_protocol.Mode.equal requested persisted ->
      Ok persisted
  | Some requested ->
      usage
        ("active turn was started in "
        ^ Spice_protocol.Mode.to_string persisted
        ^ " mode; cannot resume it with --mode "
        ^ Spice_protocol.Mode.to_string requested)

let active_turn_mode requested session =
  let state = Session.state session in
  match Session.State.active_turn state with
  | None -> Ok (mode_for_new_turn requested)
  | Some turn_id -> (
      match Session.State.turn turn_id state with
      | None ->
          Error
            (`Runtime
               ("active turn is not present in state: "
               ^ Session.Turn.Id.to_string turn_id))
      | Some turn -> mode_for_active_turn requested turn)

type reasoning_source = Flag | Config

type reasoning_request = {
  effort : Spice_llm.Request.Options.Reasoning_effort.t;
  source : reasoning_source;
}

let configured_reasoning_error error =
  Spice_diagnostic.to_string
    (Spice_diagnostic.make
       ~hints:[ "run `spice config unset reasoning` to clear it" ]
       (Spice_host.Host.Error.message error))

(* Runtime assembly. Host steps error with [Spice_host.Host.Error.t]; the only
   distinction the CLI adds is the exit class: errors caused by explicit
   [--model] input are usage errors, errors caused by host state (config or
   environment selection, gate failures on the configured model) are runtime
   errors. *)

let resolve_run_model ?reasoning_request ~stdenv host raw =
  let catalog = Spice_host.Host.catalog host in
  let* choice =
    match raw with
    | None ->
        assembly
          (Spice_host.Models.choose
             ~connected:(Spice_host.Account.connectivity ~stdenv host)
             host Model_choice.Main)
    | Some input -> invalid_input (Models.resolve catalog input)
  in
  let classify =
    match Spice_host.Reason.source (Model_choice.reason choice) with
    | Spice_host.Reason.Explicit _ -> invalid_input
    | Spice_host.Reason.Config _ | Spice_host.Reason.Derived _ -> assembly
  in
  let* () =
    let reasoning_effort =
      Option.map (fun request -> request.effort) reasoning_request
    in
    match Model_choice.require ?reasoning_effort catalog choice with
    | Ok () -> Ok ()
    | Error (Spice_host.Host.Error.Unsupported_reasoning _ as error) ->
        begin match
          Option.map (fun request -> request.source) reasoning_request
        with
        | Some Flag -> invalid_input (Error error)
        | Some Config -> Error (`Runtime (configured_reasoning_error error))
        | None -> assert false
        end
    | Error _ as error -> classify error
  in
  Ok choice

let provider_client ~sw ~stdenv host model =
  Spice_host.client ~sw ~stdenv host model

(* A missing credential on a choice nobody made is not about that provider: it
   means no provider is connected at all (a connected one would have won the
   derived default), and the recovery is any login, not that provider's. *)
let bind_client ~sw ~stdenv host choice =
  let model = Model_choice.model choice in
  match provider_client ~sw ~stdenv host model with
  | Error (Spice_host.Host.Error.Missing_credential _)
    when match Spice_host.Reason.source (Model_choice.reason choice) with
         | Spice_host.Reason.Derived _ -> true
         | Spice_host.Reason.Explicit _ | Spice_host.Reason.Config _ -> false ->
      Error
        (`Runtime
           (Spice_diagnostic.to_string
              (Spice_diagnostic.make
                 ~hints:
                   [
                     "run `spice auth login PROVIDER` to connect one";
                     "run `spice auth status` to list providers";
                   ]
                 "no provider is connected")))
  | result -> assembly result

let effective_max_steps host override =
  match override with
  | Some value -> Some value
  | None ->
      Spice_host.Config.Runtime.max_steps
        (Spice_host.Config.runtime (Spice_host.Host.config host))

let effective_reasoning host override =
  match override with
  | Some effort -> Some { effort; source = Flag }
  | None ->
      Option.map
        (fun effort -> { effort; source = Config })
        (Spice_host.Config.Models.reasoning
           (Spice_host.Config.models (Spice_host.Host.config host)))

(* JSONL execution events *)

let print_json event = stdout_printf "%s\n" (json_string event)

let json_event ~type_ session revision fields =
  json_envelope ~type_
    (( "session_id",
       Jsont.Json.string (Session.Id.to_string (Session.id session)) )
    :: ("revision", Jsont.Json.string (Session.Revision.to_string revision))
    :: fields)

let session_started_json session revision =
  json_event ~type_:"session.started" session revision []

let turn_started_json ~projection_digest ~context_warnings session revision turn
    =
  let mode_field, origin_field =
    match Session.State.turn turn (Session.state session) with
    | None -> ([], [])
    | Some turn ->
        ( (match Session.Turn.mode turn with
          | None -> []
          | Some mode -> [ ("workflow_mode", Jsont.Json.string mode) ]),
          match Session.Turn.origin turn with
          | None -> []
          | Some origin -> [ ("origin", Jsont.Json.string origin) ] )
  in
  json_event ~type_:"turn.started" session revision
    ([ ("turn_id", Jsont.Json.string (Session.Turn.Id.to_string turn)) ]
    @ mode_field @ origin_field
    @ [
        ("projection_digest", Jsont.Json.string projection_digest);
        ( "context_warnings",
          Jsont.Json.list
            (List.map
               (fun warning -> Jsont.Json.string warning)
               context_warnings) );
      ])

let permission_requested_json ~permission session revision request =
  json_event ~type_:"permission.requested" session revision
    ([
       ( "permission_id",
         Jsont.Json.string
           (Session.Permission.Id.to_string
              (Session.Permission.Requested.id request)) );
       ( "turn_id",
         Jsont.Json.string
           (Session.Turn.Id.to_string
              (Session.Permission.Requested.turn request)) );
       ( "tool_call_id",
         Jsont.Json.string
           (Tool_call.id (Session.Permission.Requested.tool_call request)) );
       ( "tool",
         Jsont.Json.string
           (Tool_call.name (Session.Permission.Requested.tool_call request)) );
       ("request", json_encode Session.Permission.Requested.jsont request);
     ]
    @ Cli_block.permission_json_fields permission request)

let permission_reply_string resolved =
  match Session.Permission.Resolved.decision resolved with
  | Session.Permission.Resolved.Allow Spice_permission.Policy.Review.Once ->
      "allow_once"
  | Session.Permission.Resolved.Allow Spice_permission.Policy.Review.Session ->
      "allow_session"
  | Session.Permission.Resolved.Deny _ -> "deny"

let permission_via_string resolved =
  match Session.Permission.Resolved.via resolved with
  | `Reviewer -> "reviewer"
  | `Unattended -> "unattended"

let permission_resolved_json session revision resolved =
  json_event ~type_:"permission.resolved" session revision
    [
      ( "permission_id",
        Jsont.Json.string
          (Session.Permission.Id.to_string
             (Session.Permission.Resolved.id resolved)) );
      ("reply", Jsont.Json.string (permission_reply_string resolved));
      ("via", Jsont.Json.string (permission_via_string resolved));
      ("resolution", json_encode Session.Permission.Resolved.jsont resolved);
    ]

let compaction_installed_json session revision compaction =
  let range_fields =
    match Session.Compaction.range compaction with
    | None -> []
    | Some range ->
        [
          ( "summarized_messages",
            Jsont.Json.int (Session.Compaction.Range.summarized_messages range)
          );
          ( "retained_tail_messages",
            Jsont.Json.int
              (Session.Compaction.Range.retained_tail_messages range) );
        ]
  in
  let model_field =
    match Session.Compaction.model compaction with
    | None -> []
    | Some model ->
        [
          ( "model",
            Jsont.Json.string (Format.asprintf "%a" Spice_llm.Model.pp model) );
        ]
  in
  json_event ~type_:"compaction.installed" session revision
    ([
       ( "reason",
         Jsont.Json.string
           (Session.Compaction.Reason.to_string
              (Session.Compaction.reason compaction)) );
       ("summary", Jsont.Json.string (Session.Compaction.summary compaction));
     ]
    @ model_field @ range_fields)

let after_save json ~projection_digest ~context_warnings ~permission_of =
  if not json then None
  else
    Some
      (fun document events ->
        let session = Store.Document.session document in
        let revision = Store.Document.revision document in
        List.iter
          (function
            | Session.Event.Turn_started turn ->
                print_json
                  (turn_started_json ~projection_digest ~context_warnings
                     session revision (Session.Turn.id turn))
            | Session.Event.Compaction_installed compaction ->
                print_json
                  (compaction_installed_json session revision compaction)
            | Session.Event.Permission_requested request ->
                print_json
                  (permission_requested_json
                     ~permission:(permission_of (Session.state session))
                     session revision request)
            | Session.Event.Permission_resolved resolved ->
                print_json (permission_resolved_json session revision resolved)
            | Session.Event.Response_appended _
            | Session.Event.Message_appended _
            | Session.Event.Tool_claim_started _
            | Session.Event.Tool_claim_finished _
            | Session.Event.Turn_finished _ ->
                ())
          events)

(* Observation rendering: the interpreter over ephemeral host observations,
   as terse human progress or schema-versioned JSONL. Lifecycle events
   describe the running command and carry no revision; durable events (such
   as [compaction.installed]) are emitted from the saved-events path with
   their post-save revision, so each prints exactly once. Human compaction
   lines carry no token numbers: counts of messages are deterministic for
   tests, heuristic token estimates are not. *)

let lifecycle_json ~type_ session_id fields =
  json_envelope ~type_
    (("session_id", Jsont.Json.string (Session.Id.to_string session_id))
    :: fields)

let render_timeline ~json ~session_id event =
  let reason_field reason =
    ("reason", Jsont.Json.string (Session.Compaction.Reason.to_string reason))
  in
  match (event : Spice_protocol.Event.t) with
  | Spice_protocol.Event.Compaction_progress
      (Spice_protocol.Event.Started
         { reason; projected_input; basis; auto_limit }) ->
      if json then
        print_json
          (lifecycle_json ~type_:"compaction.started" session_id
             ([
                reason_field reason;
                ("projected_input", Jsont.Json.int projected_input);
                ( "basis",
                  Jsont.Json.string
                    (match basis with
                    | Spice_protocol.Event.Usage -> "usage"
                    | Spice_protocol.Event.Estimate -> "estimate") );
              ]
             @
             match auto_limit with
             | None -> []
             | Some value -> [ ("auto_limit", Jsont.Json.int value) ]))
      else
        stdout_printf "compacting: %s\n"
          (Session.Compaction.Reason.to_string reason)
  | Spice_protocol.Event.Compaction_progress
      (Spice_protocol.Event.Summarizing request) ->
      if json then
        print_json
          (lifecycle_json ~type_:"compaction.model_started" session_id
             [
               ( "model",
                 Jsont.Json.string
                   (Format.asprintf "%a" Spice_llm.Model.pp
                      (Spice_llm.Request.model request)) );
             ])
  | Spice_protocol.Event.Compaction_progress
      (Spice_protocol.Event.Retrying { dropped_messages }) ->
      if json then
        print_json
          (lifecycle_json ~type_:"compaction.retrying" session_id
             [ ("dropped_messages", Jsont.Json.int dropped_messages) ])
  | Spice_protocol.Event.Compaction_progress
      (Spice_protocol.Event.Skipped { reason; message }) ->
      if json then
        print_json
          (lifecycle_json ~type_:"compaction.skipped" session_id
             [ reason_field reason; ("message", Jsont.Json.string message) ])
      else stdout_printf "compaction skipped: %s\n" message
  | Spice_protocol.Event.Compaction_progress
      (Spice_protocol.Event.Failed { reason; message }) ->
      if json then
        print_json
          (lifecycle_json ~type_:"compaction.failed" session_id
             [ reason_field reason; ("message", Jsont.Json.string message) ])
      else stdout_printf "compaction failed: %s\n" message
  (* The durable install arrives once, after its event is saved. JSON prints it
     from [after_save] with the post-install revision; the human line renders
     here. *)
  | Spice_protocol.Event.Compaction compaction ->
      if not json then begin
        (match Session.Compaction.range compaction with
        | Some range ->
            stdout_printf "compacted: summarized=%d retained=%d\n"
              (Session.Compaction.Range.summarized_messages range)
              (Session.Compaction.Range.retained_tail_messages range)
        | None -> stdout_printf "compacted\n");
        match Session.Compaction.reason compaction with
        | Session.Compaction.Reason.Context_overflow ->
            stdout_printf "retrying after compaction\n"
        | Session.Compaction.Reason.User_requested
        | Session.Compaction.Reason.Context_pressure
        | Session.Compaction.Reason.Model_downshift ->
            ()
      end
  | ( Spice_protocol.Event.Tool_started _ | Spice_protocol.Event.Tool_finished _
    | Spice_protocol.Event.Workspace_changed _ ) as event -> (
      match Cli_tool_event.of_timeline event with
      | None -> ()
      | Some event ->
          if json then
            let type_, fields = Cli_tool_event.to_json event in
            print_json (lifecycle_json ~type_ session_id fields)
          else
            Option.iter
              (fun line -> stdout_printf "%s\n" line)
              (Cli_tool_event.to_human event))
  | Spice_protocol.Event.Workspace_degraded { message } ->
      if json then
        print_json
          (lifecycle_json ~type_:"workspace.degraded" session_id
             [ ("message", Jsont.Json.string message) ])
      else stdout_printf "workspace evidence degraded: %s\n" message
  | Spice_protocol.Event.Turn_started _ | Spice_protocol.Event.Assistant _
  | Spice_protocol.Event.Host_call _
  | Spice_protocol.Event.Permission_requested _
  | Spice_protocol.Event.Permission_resolved _
  | Spice_protocol.Event.Turn_finished _
  | Spice_protocol.Event.Assistant_delta _
  | Spice_protocol.Event.Reasoning_delta _
  | Spice_protocol.Event.Usage_updated _ | Spice_protocol.Event.Model_started _
  | Spice_protocol.Event.Model_artifact _ | Spice_protocol.Event.Tool_updated _
  | Spice_protocol.Event.Notices_injected _ ->
      ()

(* Assembled execution runtime *)

type runtime = {
  model : Spice_provider.Model.t;  (** Gated model recorded on new turns. *)
  cwd : Spice_path.Abs.t;
  runner : Spice_host.Runner.t;
  notices : Spice_host.Notice_queue.t;
      (** The run's notice queue, for the ephemeral goal-context notice on
          user-initiated goal turns. *)
  stop_dune : unit -> unit;
  permission_of : Session.State.t -> Cli_block.permission_context;
      (** The one projection behind blocked rendering and saved-event metadata,
          so the surfaces cannot disagree. *)
}

let session_reply runtime document id ?message ?via reply =
  Spice_host.Runner.execute runtime.runner document
    (Spice_protocol.Command.Reply
       { permission = id; answer = reply; via; message })

(* One classification path for question waits: a valid [ask_user] payload is
   answerable, and an invalid one is still answerable so the user can unblock
   the turn. *)
let is_question_call call =
  Option.is_some
    (Option.bind
       (Spice_protocol.Call.classify call)
       Spice_protocol.Call.answerable_question)

(* The current host-tool boundary as an [Answer] token, derived from the saved
   waiting itself rather than a bare call id lookup. *)
let pending_host_tool document ~call_id ~name =
  match Session.Run.phase (Store.Document.session document) with
  | Session.Run.Phase.Waiting (Session.Waiting.Host_tool waiting)
    when String.equal (Tool_call.id waiting.Session.Waiting.call) call_id ->
      Ok waiting
  | Session.Run.Phase.Waiting _ | Session.Run.Phase.Idle
  | Session.Run.Phase.Active ->
      Error (Spice_protocol.Error.Tool_call_not_pending { call_id; name })

let pending_question_call document ~call_id =
  let* pending =
    pending_host_tool document ~call_id ~name:Spice_protocol.Question.name
  in
  if is_question_call pending.Session.Waiting.call then Ok pending
  else
    Error
      (Spice_protocol.Error.Tool_call_not_pending
         { call_id; name = Spice_protocol.Question.name })

(* The current plan boundary as its waiting token plus decoded proposal, derived
   from the saved waiting itself. A plan decision resolves this proposal and
   answers the same waiting. *)
let pending_plan_call document =
  match Session.Run.phase (Store.Document.session document) with
  | Session.Run.Phase.Waiting (Session.Waiting.Host_tool waiting) -> (
      match
        Option.bind
          (Spice_protocol.Call.classify waiting.Session.Waiting.call)
          Spice_protocol.Call.plan_proposal
      with
      | Some proposal -> Ok (waiting, proposal)
      | None ->
          Error
            (Spice_protocol.Error.Tool_call_not_pending
               {
                 call_id = Tool_call.id waiting.Session.Waiting.call;
                 name = Spice_protocol.Plan.name;
               }))
  | Session.Run.Phase.Waiting _ | Session.Run.Phase.Idle
  | Session.Run.Phase.Active ->
      Error
        (Spice_protocol.Error.Tool_call_not_pending
           { call_id = ""; name = Spice_protocol.Plan.name })

let turn_final_text session turn =
  Session.State.turn_final_text turn (Session.state session)
  |> Option.value ~default:""

(* Sandbox posture facts shown at run start: human lines on stderr, one
   stream-level run.started event in JSON mode. Stdout stays content-only.
   All fact vocabulary comes from [Spice_host.Sandbox.Effective] so this
   summary cannot disagree with [spice sandbox status]/[explain]. *)
let run_started ~json ~preset effective =
  let module Effective = Spice_host.Sandbox.Effective in
  let module Status = Spice_host.Sandbox.Status in
  let permission = Spice_host.Permission.Preset.to_string preset in
  let status = Effective.status effective in
  let mode = status.Status.mode in
  let mode_string = Spice_host.Sandbox.Mode.to_string mode in
  let origin = Status.origin_string status.Status.origin in
  let backend = status.Status.backend in
  let require = Spice_host.Sandbox.Require.to_string status.Status.require in
  let network = Status.network_string status.Status.network in
  let enforcement = Status.enforcement_string status.Status.enforcement in
  if json then
    print_json
      (Cli_common.json_envelope ~type_:"run.started"
         [
           ( "permission",
             Cli_common.json_obj [ ("mode", Jsont.Json.string permission) ] );
           ( "sandbox",
             Cli_common.json_obj
               [
                 ("mode", Jsont.Json.string mode_string);
                 ("origin", Jsont.Json.string origin);
                 ("require", Jsont.Json.string require);
                 ("network", Jsont.Json.string network);
                 ("backend", Jsont.Json.string backend);
                 ("enforcement", Jsont.Json.string enforcement);
               ] );
         ])
  else begin
    Cli_common.stderr_printf
      "permission: %s\nsandbox: %s (%s)\nbackend: %s %s\nnetwork: %s\n"
      permission mode_string origin backend enforcement network;
    match mode with
    | Spice_host.Sandbox.Mode.Danger_full_access ->
        Cli_common.stderr_printf
          "warning: command sandbox disabled by explicit user choice\n"
    | Spice_host.Sandbox.Mode.Read_only
    | Spice_host.Sandbox.Mode.Workspace_write
    | Spice_host.Sandbox.Mode.External_sandbox ->
        ()
  end

let assemble ?cwd_override_abs ?skills:preloaded_skills ~sw ~stdenv ~json ~store
    ~session_id host ~mode ~model ~reasoning_request ~permission_mode ~sandbox
    ~max_steps =
  (* The sandbox posture resolves and gates before model resolution, provider
     credentials, and any session mutation. The gate, run-start summary, and
     model/client resolution stay here because their order is user-observable
     (the summary prints between the gate and a model-selection error), then
     [Run.start] composes the run mechanics over the gated plan. *)
  let* workspace = assembly (Spice_host.workspace host) in
  let effective = resolve_sandbox host ~workspace sandbox in
  let permission = permission_args host permission_mode in
  let* plan =
    Spice_host.Run.plan ~workspace ~sandbox:effective ~permission ()
    |> Result.map_error (fun error ->
        `Runtime (Spice_host.Sandbox.Gate_error.message error))
  in
  let permission_of =
    Cli_block.permission_context permission ~workflow_mode:mode
  in
  run_started ~json
    ~preset:(Spice_host.Permission.Run.preset permission)
    effective;
  let* choice = resolve_run_model ?reasoning_request ~stdenv host model in
  let model = Model_choice.model choice in
  let* client = bind_client ~sw ~stdenv host choice in
  let* run =
    assembly
      (Spice_host.Run.start ~sw ~stdenv host plan ~store ~session:session_id
         ~http:(Spice_host_builtin.web_http_client stdenv)
         ~fetch_https:(Spice_host_builtin.web_fetch_https ())
         ?max_steps ?skills:preloaded_skills ?cwd_override:cwd_override_abs ())
  in
  let stop_dune () = Spice_host.Run.stop run in
  (* A goal-driven run settles several turns in one invocation, so the
     producers must outlive each settle; teardown stays with the caller's
     [Fun.protect ~finally:stop_dune]. Goal-less runs keep the prompt
     stop-on-settle. *)
  let goal_driven =
    match
      Spice_host.Artifacts.Goal.load ~fs:(Eio.Stdenv.fs stdenv)
        ~root:(Store.root store |> Spice_path.Abs.to_string)
        session_id
    with
    | Ok (Some goal) -> Spice_protocol.Goal.is_unfinished goal
    | Ok None | Error _ -> false
  in
  let* runner = assembly (Spice_host.Run.runner run ~mode ~model ~client) in
  let runner =
    runner
    |> Spice_host.Runner.with_hooks (fun hooks ->
        let hooks =
          hooks |> Host_session.with_observe (render_timeline ~json ~session_id)
        in
        let hooks =
          if goal_driven then hooks
          else
            Host_session.with_terminal_observed
              (fun ~observe:_ _ -> stop_dune ())
              hooks
        in
        match
          after_save json
            ~projection_digest:
              (Spice_host.Context.rendered_digest (Spice_host.Run.context run))
            ~context_warnings:
              (Spice_host.Context.warnings (Spice_host.Run.context run))
            ~permission_of
        with
        | None -> hooks
        | Some after_save -> Host_session.with_after_save after_save hooks)
  in
  let cwd = Spice_host.Run.cwd run in
  Ok
    {
      model;
      cwd;
      runner;
      notices = Spice_host.Run.notices run;
      stop_dune;
      permission_of;
    }

(* [spice session compact] runs no tools: it only needs the summary model
   client and the compaction policy. *)
let summary_compaction ~sw ~stdenv host model =
  let* choice = resolve_run_model ~stdenv host model in
  let model = Model_choice.model choice in
  let* client = bind_client ~sw ~stdenv host choice in
  assembly
    (let* context = host_context ~stdenv host in
     Ok
       ( client,
         Spice_host.Compactor.Policy.of_model
           ~prelude:(Spice_host.Context.to_prelude context)
           model ))

(* Result rendering *)

let outcome_string = Cli_block.outcome_string
let result_document (document, _outcome) = document

let metrics_json session =
  Session.Metrics.of_session session |> json_encode Session.Metrics.jsont

let result_jsonl ~permission_of ~duration_ms (document, outcome) =
  let session = Store.Document.session document in
  let revision = Store.Document.revision document in
  let final_fields =
    [
      ("metrics", metrics_json session);
      ("duration_ms", Jsont.Json.int duration_ms);
    ]
  in
  match outcome with
  | Spice_protocol.Outcome.Waiting { waiting; _ } ->
      let state = Session.state session in
      json_event ~type_:"session.waiting" session revision
        ([
           ("waiting", Cli_block.json ~permission:(permission_of state) waiting);
         ]
        @ final_fields)
  | Spice_protocol.Outcome.Finished { turn; outcome } ->
      json_event ~type_:"turn.finished" session revision
        ([
           ("turn_id", Jsont.Json.string (Session.Turn.Id.to_string turn));
           ("outcome", Jsont.Json.string (outcome_string outcome));
           ("final_text", Jsont.Json.string (turn_final_text session turn));
         ]
        @ final_fields)

(* Failed executions still end the JSONL stream with one terminal event, so
   consumers can distinguish a failed run from a severed stream and the spend
   the session durably recorded stays accounted. Host errors do not carry the
   document, so it is reloaded; a session that never persisted yields an
   event without revision or metrics. *)
let execution_error_kind = function
  | Spice_protocol.Error.Provider error -> (
      match Spice_llm.Error.kind error with
      | Spice_llm.Error.Provider -> "provider"
      | kind -> "provider_" ^ Spice_llm.Error.label kind)
  | Spice_protocol.Error.Conflict _ -> "conflict"
  | Spice_protocol.Error.Not_found _ -> "not_found"
  | Spice_protocol.Error.Storage _ -> "storage"
  | Spice_protocol.Error.Invalid_answer _ -> "invalid_answer"
  | Spice_protocol.Error.Archived _ -> "archived"
  | Spice_protocol.Error.Deleted _ -> "deleted"
  | Spice_protocol.Error.Active_turn_exists _ -> "active_turn_exists"
  | Spice_protocol.Error.No_active_turn -> "no_active_turn"
  | Spice_protocol.Error.Permission_not_pending _ -> "permission_not_pending"
  | Spice_protocol.Error.Tool_claim_not_pending _ -> "tool_claim_not_pending"
  | Spice_protocol.Error.Tool_call_not_pending _ -> "tool_call_not_pending"
  | Spice_protocol.Error.Transcript_not_ready _ -> "transcript_not_ready"
  | Spice_protocol.Error.Nothing_to_summarize -> "nothing_to_summarize"
  | Spice_protocol.Error.No_compaction_model -> "no_compaction_model"
  | Spice_protocol.Error.Empty_compaction_summary -> "empty_compaction_summary"
  | Spice_protocol.Error.Internal _ -> "internal"

let print_failed_event ~stdenv ~store ~id ~started error =
  let state_fields =
    match Store.load store id with
    | Ok document ->
        let session = Store.Document.session document in
        [
          ( "revision",
            Jsont.Json.string
              (Session.Revision.to_string (Store.Document.revision document)) );
          ("metrics", metrics_json session);
        ]
    | Error _ -> []
  in
  let fields =
    (("session_id", Jsont.Json.string (Session.Id.to_string id)) :: state_fields)
    @ [
        ( "error",
          json_obj
            [
              ("kind", Jsont.Json.string (execution_error_kind error));
              ( "message",
                Jsont.Json.string
                  (Spice_diagnostic.to_string
                     (Spice_protocol.Error.diagnostic error)) );
            ] );
        ("duration_ms", Jsont.Json.int (duration_ms ~started stdenv));
      ]
  in
  print_json (json_envelope ~type_:"session.failed" fields)

let execution_terminal ~json ~stdenv ~store ~id ~started result =
  (match result with
  | Error error when json ->
      print_failed_event ~stdenv ~store ~id ~started error
  | Ok _ | Error _ -> ());
  execution result

let block_human ~permission_of session block =
  let id = Session.id session in
  let detail =
    match block with
    | Spice_session.Waiting.Permission request ->
        Cli_block.permission_lines
          (permission_of (Session.state session))
          request
    | Spice_session.Waiting.Host_tool _ -> Cli_block.plan_lines block
    | Spice_session.Waiting.Tool_claim _ -> []
  in
  String.concat "\n"
    (("session " ^ Session.Id.to_string id ^ " " ^ Cli_block.human block)
     :: detail
    @ Cli_block.commands ~session:id block)

(* Finished runs always leave a copy-pasteable continuation on the diagnostic
   stream; JSONL stdout is unaffected. *)
let print_saved_hint session =
  stderr_printf "spice: session saved; resume with: %s\n"
    (Cli_block.resume_invocation ~session:(Session.id session))

(* Ephemeral runs store the session under a throwaway root removed when the
   run ends, so one-shot scripted calls leave nothing in the session store.
   A blocked ephemeral session is discarded with it: the blocked exit code is
   the only durable fact. *)
let rec remove_tree path =
  match Sys.is_directory path with
  | true -> (
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      try Unix.rmdir path with Unix.Unix_error _ -> ())
  | false -> ( try Sys.remove path with Sys_error _ -> ())
  | exception Sys_error _ -> ()

let with_run_store ~stdenv ~ephemeral host f =
  if not ephemeral then f (Host_session.store ~stdenv host)
  else
    let root_text = Filename.temp_dir "spice-ephemeral" "" in
    let root = Spice_path.Abs.of_string_exn root_text in
    Fun.protect
      ~finally:(fun () -> remove_tree root_text)
      (fun () ->
        f
          (Store.make ~fs:(Eio.Stdenv.fs stdenv)
             ~clock:(Eio.Stdenv.clock stdenv) ~root))

(* Run trailer: the changed-file summary and the diff/revert hints, printed
   when a finished turn recorded mutation evidence. JSONL mode carries the
   same facts in [workspace.changed] events. *)
let print_changed_trailer ~json ~stdenv ~store (document, outcome) =
  if json then ()
  else
    match outcome with
    | Spice_protocol.Outcome.Waiting _ -> ()
    | Spice_protocol.Outcome.Finished { turn; _ } -> (
        let session_id = Session.id (Store.Document.session document) in
        let log =
          Spice_host.Mutations.Log.make ~fs:(Eio.Stdenv.fs stdenv)
            ~root:(Store.root store |> Spice_path.Abs.to_string)
        in
        match Spice_host.Mutations.Log.read log ~session:session_id with
        | Error _ -> ()
        | Ok records ->
            let changes =
              Spice_mutation.Scope.select (Spice_mutation.Scope.Turn turn)
                (Spice_mutation.changes records)
            in
            if changes <> [] then begin
              let totals = Spice_mutation.Change.totals changes in
              let plural =
                if totals.Spice_mutation.Change.files = 1 then "file"
                else "files"
              in
              stdout_printf "changed %d %s (+%d -%d)\n"
                totals.Spice_mutation.Change.files plural
                totals.Spice_mutation.Change.total_additions
                totals.Spice_mutation.Change.total_deletions;
              (* Route the id through [Cli_block.positional_arg] and put the flag
                 first so the hint survives copy-paste for a dash-prefixed id,
                 which cmdliner would otherwise read as an option. *)
              let sid =
                Cli_block.positional_arg (Session.Id.to_string session_id)
              in
              stdout_printf "diff: spice session diff --latest %s\n" sid;
              stdout_printf "revert: spice session revert --latest %s\n" sid
            end)

(* The headless drive boundary. A finished turn renders its outcome; a blocked
   turn renders the continuation commands and exits with the dedicated blocked
   code, and the caller re-invokes [spice run reply] with a decision. *)
let print_result ?(saved_hint = true) ~json ~permission_of ~duration_ms
    ((document, outcome) as result) =
  let session = Store.Document.session document in
  if json then (
    print_json (result_jsonl ~permission_of ~duration_ms result);
    match outcome with
    | Spice_protocol.Outcome.Finished
        { outcome = Spice_session.Turn.Outcome.Failed _; _ } ->
        (* The failure and its message are already in the emitted JSONL; exit
           non-zero so scripts branch on it, without a second stderr line. *)
        Failed
    | Spice_protocol.Outcome.Finished _ ->
        if saved_hint then print_saved_hint session;
        Success
    | Spice_protocol.Outcome.Waiting _ -> Blocked "session blocked")
  else
    match outcome with
    | Spice_protocol.Outcome.Finished
        { outcome = Spice_session.Turn.Outcome.Failed { message }; _ } ->
        (* A turn that failed before a normal terminal point is not a success:
           exit non-zero and surface why, rather than folding into [Success]. *)
        Runtime_error message
    | Spice_protocol.Outcome.Finished { turn; _ } ->
        let text = turn_final_text session turn in
        if not (String.is_empty text) then stdout_printf "%s\n" text;
        if saved_hint then print_saved_hint session;
        Success
    | Spice_protocol.Outcome.Waiting { waiting; _ } ->
        Blocked (block_human ~permission_of session waiting)

(* The unattended reply policy: under [deny], a needed review is resolved
   immediately as a denial with stable model-visible feedback and distinct
   audit provenance, and the run continues — it can never allow, grant, or
   write rules. Repeated reviews are bounded by the turn's step limit. Other
   waiting (host questions, unfinished tools) still park the session. *)
let unattended_denial_message = "Permission denied: unattended run."

let rec resolve_unattended ~unattended runtime result =
  match result with
  | Ok
      ( document,
        Spice_protocol.Outcome.Waiting
          { waiting = Spice_session.Waiting.Permission request; _ } )
    when Spice_host.Permission.Unattended.equal unattended
           Spice_host.Permission.Unattended.Deny ->
      resolve_unattended ~unattended runtime
        (session_reply runtime document
           (Session.Permission.Requested.id request)
           ~message:unattended_denial_message ~via:`Unattended
           Spice_permission.Policy.Review.Deny)
  | result -> result

let effective_unattended host override =
  Option.value override
    ~default:
      (Spice_host.Config.Permissions.unattended
         (Spice_host.Config.permissions (Spice_host.Host.config host)))

let make_turn ?(skill_texts = []) ?origin stdenv model mode prompt max_steps
    ~reasoning_request =
  let reasoning_effort =
    match reasoning_request with
    | Some request -> Some request.effort
    | None -> Spice_provider.Model.default_reasoning model
  in
  let options = Spice_host.Turn_options.resolve ~model ?reasoning_effort () in
  let host_tools =
    List.map Spice_protocol.Call.Kind.name (Spice_protocol.Mode.host_tools mode)
  in
  let input =
    (* [--skill] texts are durable user content blocks ahead of the prompt
       block, so forced guidance survives resume like a /name expansion. *)
    match skill_texts with
    | [] -> Session.Turn.Input.user_text prompt
    | texts ->
        Session.Turn.Input.user
          (List.map Spice_llm.Content.text (texts @ [ prompt ]))
  in
  Session.Turn.make ~id:(fresh_turn_id stdenv) ~input
    ~model:(Spice_provider.Model.llm model)
    ~options
    ~mode:(Spice_protocol.Mode.to_string mode)
    ?origin ?max_steps ~host_tools ()

(* Goal-driven execution. The host owns the decision and the safety
   transitions ([Spice_host.Goal_run]); this loop owns launching: it settles
   accounting after every execute, re-consults the continuation decision, and
   submits the next goal turn until the goal leaves [active], the turn parks,
   or the user interrupts. *)

let goal_store_paths ~stdenv ~store =
  (Eio.Stdenv.fs stdenv, Store.root store |> Spice_path.Abs.to_string)

let fresh_goal_id stdenv =
  match Goal.Id.of_string (fresh_id stdenv "goal") with
  | Ok id -> id
  | Error message -> invalid_arg message

(* Artifact storage failures during goal driving are execution failures, the
   same mapping the host handler applies. *)
let goal_execution_error = function
  | Spice_host.Artifacts.Error.Corrupt_file { path; message }
  | Spice_host.Artifacts.Error.Io { path; message } ->
      Spice_protocol.Error.Storage { path; message }
  | ( Spice_host.Artifacts.Error.Not_found _
    | Spice_host.Artifacts.Error.Conflict _ ) as error ->
      Spice_protocol.Error.Internal (Spice_host.Artifacts.Error.message error)

let goal_verb_result = function
  | Ok goal -> Ok goal
  | Error (Goal_run.Refused message) -> Error (`Runtime message)
  | Error (Goal_run.Storage error) -> Error (`Sidecar error)

let truncated_objective goal =
  let objective = Goal.objective goal in
  let limit = 72 in
  (* Walk the byte budget back over UTF-8 continuation bytes so the cut never
     splits a scalar; a newline before [limit] is ASCII, already a boundary. *)
  let boundary i =
    let rec back j =
      if j > 0 && Char.code objective.[j] land 0xC0 = 0x80 then back (j - 1)
      else j
    in
    back i
  in
  match String.index_opt objective '\n' with
  | Some cut when cut <= limit -> String.sub objective 0 cut ^ "…"
  | _ ->
      if String.length objective <= limit then objective
      else String.sub objective 0 (boundary limit) ^ "…"

let goal_budget_suffix goal =
  match Goal.token_budget goal with
  | None -> ""
  | Some budget ->
      Printf.sprintf " (tokens %d/%d)" (Goal.tokens_used goal) budget

let goal_line goal =
  Printf.sprintf "goal %s: %s — %s%s"
    (Goal.Id.to_string (Goal.id goal))
    (Goal.Status.to_string (Goal.status goal))
    (truncated_objective goal) (goal_budget_suffix goal)

let goal_resume_invocation ~session =
  (* Flag before the positional id, id through [Cli_block.positional_arg], so the
     hint survives copy-paste even for a dash-prefixed session id. *)
  "spice run reply --resume-goal "
  ^ Cli_block.positional_arg (Session.Id.to_string session)

let goal_json_fields goal =
  [
    ("goal_id", Jsont.Json.string (Goal.Id.to_string (Goal.id goal)));
    ("status", Jsont.Json.string (Goal.Status.to_string (Goal.status goal)));
    ("objective", Jsont.Json.string (Goal.objective goal));
    ("tokens_used", Jsont.Json.int (Goal.tokens_used goal));
    ("time_used_ms", Jsont.Json.int (Goal.time_used_ms goal));
    ("continuation_turns", Jsont.Json.int (Goal.continuation_turns goal));
  ]
  @
  match Goal.token_budget goal with
  | None -> []
  | Some budget ->
      [
        ("token_budget", Jsont.Json.int budget);
        ( "tokens_remaining",
          Jsont.Json.int (Option.value (Goal.remaining_tokens goal) ~default:0)
        );
      ]

(* One typed event per goal transition: the event name is the status the goal
   just entered. [goal.set] and [goal.objective_updated] are emitted at their
   verbs, which do not change status. *)
let goal_event_type goal =
  match Goal.status goal with
  | Goal.Status.Active -> "goal.resumed"
  | Goal.Status.Paused -> "goal.paused"
  | Goal.Status.Blocked _ -> "goal.blocked"
  | Goal.Status.Budget_limited -> "goal.budget_limited"
  | Goal.Status.Completed _ -> "goal.completed"
  | Goal.Status.Cleared -> "goal.cleared"

let print_goal_event ~json ~type_ session_id goal =
  if json then
    print_json (lifecycle_json ~type_ session_id (goal_json_fields goal))
  else stderr_printf "spice: %s\n" (goal_line goal)

(* Human trailer for a goal that stopped: what happened and the exact next
   command. Completed budgeted goals report final usage. *)
let print_goal_trailer ~json ~session goal =
  if json then ()
  else
    match Goal.status goal with
    | Goal.Status.Active -> ()
    | Goal.Status.Completed _ -> (
        match Goal.token_budget goal with
        | None -> ()
        | Some budget ->
            stderr_printf "spice: goal completed with %d of %d budget tokens\n"
              (Goal.tokens_used goal) budget)
    | Goal.Status.Cleared -> ()
    | Goal.Status.Paused | Goal.Status.Blocked _ | Goal.Status.Budget_limited ->
        stderr_printf "spice: resume the goal with: %s\n"
          (goal_resume_invocation ~session)

(* SIGINT on a goal run interrupts the turn instead of killing the process:
   the runner samples the flag, the turn settles as interrupted, and the
   settle pauses the goal — never left [active] with no driver by this path.
   Installed only when a goal is driving, so goal-less runs keep the default
   Ctrl-C behavior. *)
let with_goal_sigint runtime f =
  let cancelled = ref false in
  let runner =
    Spice_host.Runner.with_hooks
      (Host_session.with_cancelled (fun () -> !cancelled))
      runtime.runner
  in
  let previous =
    Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> cancelled := true))
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.signal Sys.sigint previous))
    (fun () -> f { runtime with runner })

(* Executes commands with goal accounting and continuation. Each settle
   accrues the turn's tokens and active time onto the artifact and applies
   the safety transitions; a clean build settle re-consults the host decision
   — which re-reads the artifact, so a lifecycle verb that landed mid-turn
   wins — and launches the continuation turn it returns. Transition events
   are emitted by comparing stored status across the settle. *)
let drive_goal ~stdenv ~store ~json ~unattended ~mode ~max_steps
    ~reasoning_request runtime document command =
  let fs, root = goal_store_paths ~stdenv ~store in
  let session_id = Session.id (Store.Document.session document) in
  let goal_before () =
    match Spice_host.Artifacts.Goal.load ~fs ~root session_id with
    | Ok goal -> goal
    | Error _ -> None
  in
  let emit_transition ~before ~after =
    match (before, after) with
    | Some before, Some after
      when not (Goal.Status.equal (Goal.status before) (Goal.status after)) ->
        print_goal_event ~json ~type_:(goal_event_type after) session_id after
    | _ -> ()
  in
  let rec exec runtime document command =
    let before_goal = goal_before () in
    let before = Session.Metrics.of_session (Store.Document.session document) in
    let started = monotonic_now stdenv in
    let result =
      resolve_unattended ~unattended runtime
        (Spice_host.Runner.execute runtime.runner document command)
    in
    match result with
    | Error error ->
        (* A turn error blocks the goal so automatic continuation cannot loop
           through provider failures. Best-effort: the run is already
           failing. *)
        (match before_goal with
        | Some goal when Goal.may_update goal -> (
            let reason =
              Spice_diagnostic.to_string (Spice_protocol.Error.diagnostic error)
            in
            match Goal.block ~blocked_at:(now stdenv) ~reason goal with
            | Ok goal -> (
                match Spice_host.Artifacts.Goal.save ~fs ~root goal with
                | Ok () ->
                    print_goal_event ~json ~type_:"goal.blocked" session_id goal
                | Error _ -> ())
            | Error _ -> ())
        | Some _ | None -> ());
        Error error
    | Ok ((document, outcome) as settled) -> (
        let after =
          Session.Metrics.of_session (Store.Document.session document)
        in
        let tokens = Goal_run.turn_tokens ~before ~after in
        let active_ms = duration_ms ~started stdenv in
        match
          Goal_run.settle ~fs ~root ~now:(now stdenv) ~document ~outcome ~tokens
            ~active_ms
        with
        | Error error -> Error (goal_execution_error error)
        | Ok after_goal -> (
            emit_transition ~before:before_goal ~after:after_goal;
            match
              Goal_run.continuation ~fs ~root ~session:session_id ~mode outcome
            with
            | Error error -> Error (goal_execution_error error)
            | Ok None -> Ok settled
            | Ok (Some (goal, prompt)) ->
                (* The final settle is printed by [print_result]; the settles
                   the loop drives past each get their own terminal event so
                   the JSONL stream pairs every turn.started with an end. *)
                if json then
                  print_json
                    (result_jsonl ~permission_of:runtime.permission_of
                       ~duration_ms:active_ms settled)
                else
                  stderr_printf "spice: goal: continuing (turn %d)\n"
                    (Goal.continuation_turns goal + 1);
                let turn =
                  make_turn ~origin:Goal.turn_origin stdenv runtime.model mode
                    prompt max_steps ~reasoning_request
                in
                exec runtime document (Spice_protocol.Command.Start turn)))
  in
  match goal_before () with
  | Some goal when Goal.is_unfinished goal ->
      (* User-initiated entry into a goal session: remind the model of the
         goal ephemerally. Continuation turns carry it in their prompt. *)
      Spice_host.Notice_queue.publish runtime.notices
        (Goal_run.context_notice goal);
      with_goal_sigint runtime (fun runtime ->
          let result = exec runtime document command in
          (match goal_before () with
          | Some goal -> print_goal_trailer ~json ~session:session_id goal
          | None -> ());
          result)
  | Some _ | None -> exec runtime document command

let debug_enabled () =
  match Sys.getenv_opt "SPICE_DEBUG" with Some "1" -> true | _ -> false

let auto_title_enabled () =
  match Sys.getenv_opt "SPICE_AUTO_TITLE" with Some "0" -> false | _ -> true

let debug_title_failure message =
  if debug_enabled () then
    stderr_printf "spice: auto-title skipped: %s\n" message

(* Titling is best-effort housekeeping after the run's durable outcome; a
   stalled transport must never hang process exit, so the one request runs
   under a hard deadline with a deadline-derived cooperative cancel. *)
let title_deadline_seconds = 10.0

let maybe_generate_title ~sw ~stdenv host store document =
  if auto_title_enabled () then
    let session = Store.Document.session document in
    if Option.is_none (Session.Metadata.title (Session.metadata session)) then
      match
        Spice_host.Models.choose
          ~connected:(Spice_host.Account.connectivity ~stdenv host)
          host Model_choice.Small
      with
      | Error error -> debug_title_failure (Spice_host.Host.Error.message error)
      | Ok choice -> (
          let model = Model_choice.model choice in
          match provider_client ~sw ~stdenv host model with
          | Error error ->
              debug_title_failure (Spice_host.Host.Error.message error)
          | Ok client -> (
              let clock = Eio.Stdenv.clock stdenv in
              let deadline = Eio.Time.now clock +. title_deadline_seconds in
              let cancelled () = Eio.Time.now clock >= deadline in
              match
                Eio.Time.with_timeout clock title_deadline_seconds (fun () ->
                    Host_session.generate_title ~store ~client ~cancelled
                      ~model:(Spice_provider.Model.llm model)
                      document
                    |> Result.map_error (fun error -> `Title error))
              with
              | Ok _ -> ()
              | Error `Timeout -> debug_title_failure "title request timed out"
              | Error (`Title error) ->
                  debug_title_failure (Spice_protocol.Error.message error)))

(* Turns *)

(* Execution verbs *)

let start json raw_id title model reasoning_effort workflow_mode permission_mode
    permission_unattended sandbox ephemeral max_steps cwd overrides skill_names
    goal_objective goal_budget prompt =
  let cwd_override_abs =
    Option.bind cwd (fun raw ->
        match Spice_path.Abs.of_string (Sys.getcwd ()) with
        | Error _ -> None
        | Ok base -> Result.to_option (Spice_path.Abs.resolve_any ~base raw))
  in
  with_host ?cwd ~overrides @@ fun ~stdenv host ->
  let started = monotonic_now stdenv in
  Eio.Switch.run @@ fun sw ->
  with_run_store ~stdenv ~ephemeral host @@ fun store ->
  status
    (let* () =
       match (goal_objective, goal_budget) with
       | None, Some _ -> usage "--goal-budget requires --goal"
       | (Some _ | None), _ -> Ok ()
     in
     let* () =
       match (goal_objective, workflow_mode) with
       | Some _, Some (Spice_protocol.Mode.Plan | Spice_protocol.Mode.Review) ->
           usage "--goal requires build mode"
       | _ -> Ok ()
     in
     (* With --goal and no PROMPT, the objective seeds the first turn. *)
     let* prompt =
       match (prompt, goal_objective) with
       | None, Some objective -> Ok objective
       | prompt, _ -> read_prompt prompt
     in
     let* () = validate_max_steps max_steps in
     let mode = mode_for_new_turn workflow_mode in
     let max_steps = effective_max_steps host max_steps in
     let reasoning_request = effective_reasoning host reasoning_effort in
     let id = Option.value raw_id ~default:(fresh_session_id stdenv) in
     let* preloaded_skills, skill_texts =
       match skill_names with
       | [] -> Ok (None, [])
       | _ ->
           let skills = host_skills ~stdenv host in
           let* skill_texts =
             match Spice_host.Skills.injections skills ~names:skill_names with
             | Ok texts -> Ok texts
             | Error message -> usage message
           in
           Ok (Some skills, skill_texts)
     in
     let* () = validate_title title in
     (* The goal is set before assembly so the run's catalog offers
        [update_goal] from the first turn. *)
     let* goal =
       match goal_objective with
       | None -> Ok None
       | Some objective ->
           let fs, root = goal_store_paths ~stdenv ~store in
           goal_verb_result
             (Goal_run.set_goal ~fs ~root ~id:(fresh_goal_id stdenv) ~session:id
                ~objective ?token_budget:goal_budget ~now:(now stdenv) ())
           |> Result.map Option.some
     in
     let* ({ model; cwd; stop_dune; permission_of; _ } as runtime) =
       assemble ?cwd_override_abs ?skills:preloaded_skills ~sw ~stdenv ~json
         ~store ~session_id:id host ~mode ~model ~reasoning_request
         ~permission_mode ~sandbox ~max_steps
     in
     let session = Session.create ~id ?title ~cwd ~created_at:(now stdenv) () in
     let* document = session_store ~id (Store.create store session) in
     if json then
       print_json
         (session_started_json
            (Store.Document.session document)
            (Store.Document.revision document));
     (match goal with
     | Some goal -> print_goal_event ~json ~type_:"goal.set" id goal
     | None -> ());
     let turn =
       make_turn ~skill_texts stdenv model mode prompt max_steps
         ~reasoning_request
     in
     let* result =
       Fun.protect ~finally:stop_dune (fun () ->
           execution_terminal ~json ~stdenv ~store ~id ~started
             (drive_goal ~stdenv ~store ~json
                ~unattended:(effective_unattended host permission_unattended)
                ~mode ~max_steps ~reasoning_request runtime document
                (Spice_protocol.Command.Start turn)))
     in
     print_changed_trailer ~json ~stdenv ~store result;
     let status =
       print_result ~saved_hint:(not ephemeral) ~json ~permission_of
         ~duration_ms:(duration_ms ~started stdenv)
         result
     in
     if not ephemeral then
       maybe_generate_title ~sw ~stdenv host store (result_document result);
     Ok status)

let resume_in_host ~stdenv host json model reasoning_effort workflow_mode
    permission_mode permission_unattended sandbox max_steps id prompt =
  let started = monotonic_now stdenv in
  Eio.Switch.run @@ fun sw ->
  status
    (let store = Host_session.store ~stdenv host in
     let* document = locate_session ~store id in
     let session = Store.Document.session document in
     let id = Session.id session in
     let* () = validate_max_steps max_steps in
     let active_turn = Session.State.active_turn (Session.state session) in
     let* mode = active_turn_mode workflow_mode session in
     let* prompt =
       match (active_turn, prompt) with
       | Some _, Some _ ->
           usage "run resume cannot accept PROMPT while a turn is active"
       | Some _, None -> Ok None
       | None, None -> usage "run resume requires PROMPT when no turn is active"
       | None, Some raw -> Result.map Option.some (read_prompt (Some raw))
     in
     let max_steps = effective_max_steps host max_steps in
     let reasoning_request = effective_reasoning host reasoning_effort in
     let* ({ model; stop_dune; permission_of; _ } as runtime) =
       assemble ~sw ~stdenv ~json ~store ~session_id:id host ~mode ~model
         ~reasoning_request ~permission_mode ~sandbox ~max_steps
     in
     let* result =
       Fun.protect ~finally:stop_dune (fun () ->
           execution_terminal ~json ~stdenv ~store ~id ~started
             (drive_goal ~stdenv ~store ~json
                ~unattended:(effective_unattended host permission_unattended)
                ~mode ~max_steps ~reasoning_request runtime document
                (match prompt with
                | None -> Spice_protocol.Command.Resume
                | Some prompt ->
                    Spice_protocol.Command.Start
                      (make_turn stdenv model mode prompt max_steps
                         ~reasoning_request))))
     in
     print_changed_trailer ~json ~stdenv ~store result;
     let status =
       print_result ~json ~permission_of
         ~duration_ms:(duration_ms ~started stdenv)
         result
     in
     maybe_generate_title ~sw ~stdenv host store (result_document result);
     Ok status)

let resume json model reasoning_effort workflow_mode permission_mode
    permission_unattended sandbox max_steps cwd overrides id prompt =
  with_host ?cwd ~overrides @@ fun ~stdenv host ->
  resume_in_host ~stdenv host json model reasoning_effort workflow_mode
    permission_mode permission_unattended sandbox max_steps id prompt

(* Continuations feed a decision back into a blocked session. The flags name
   the decision; [resolve_continuation] turns it into a host verb, and the
   host validates ids against the loaded document once the runtime is
   assembled — bad ids fail with structured workflow errors before anything
   is recorded. Every verb advances to the next boundary itself; no separate
   resume follows a reply. *)

type continuation =
  | Permission_reply of {
      id : Session.Permission.Id.t;
      answer : Spice_permission.Policy.Review.answer;
      message : string option;
    }
  | Question_answer of { call_id : string; answer : string }
  | Plan_decision of Spice_protocol.Plan.Decision.t
  | Tool_claim_interrupted of { id : Session.Tool_claim.Id.t; reason : string }

type action =
  | Reply of {
      id : Session.Permission.Id.t;
      answer : Spice_permission.Policy.Review.answer;
      message : string option;
    }
  | Answer_question of { pending : Session.Waiting.host_tool; text : string }
  | Finish of {
      id : Session.Tool_claim.Id.t;
      result : Spice_tool.Output.t Spice_tool.Result.t;
    }

let resolve_continuation ~fs ~root ~now document = function
  | Permission_reply { id; answer; message } ->
      Ok (Reply { id; answer; message })
  | Question_answer { call_id; answer } ->
      let* pending = execution (pending_question_call document ~call_id) in
      let* text =
        Spice_protocol.Question.answer_text answer
        |> Result.map_error (fun message -> `Runtime message)
      in
      Ok (Answer_question { pending; text })
  | Plan_decision decision ->
      (* Resolving transitions the stored plan artifact and yields the
         model-visible answer text, which drives the same [Answer] path as a
         question. Answering the plan block with the generic [--answer] bypasses
         this transition; that is the documented interim behavior. *)
      let* pending, proposal = execution (pending_plan_call document) in
      let* text =
        sidecar
          (Spice_host.Artifacts.Plan.resolve ~fs ~root ~now ~decision proposal)
      in
      Ok (Answer_question { pending; text })
  | Tool_claim_interrupted { id; reason } ->
      let result = Spice_tool.Result.interrupted ~reason ~cancelled:false () in
      Ok (Finish { id; result })

let continue json model reasoning_effort workflow_mode permission_mode
    permission_unattended sandbox max_steps cwd overrides last session_ref
    continuation =
  with_host ?cwd ~overrides @@ fun ~stdenv host ->
  let started = monotonic_now stdenv in
  Eio.Switch.run @@ fun sw ->
  status
    (let store = Host_session.store ~stdenv host in
     let* document =
       resolve_session_target ~command:"run reply" ~surface:`Headless ~stdenv
         host ~last session_ref
     in
     let session = Store.Document.session document in
     let id = Session.id session in
     let* mode = active_turn_mode workflow_mode session in
     let* () = validate_max_steps max_steps in
     let* action =
       resolve_continuation ~fs:(Eio.Stdenv.fs stdenv)
         ~root:(Store.root store |> Spice_path.Abs.to_string)
         ~now:(now stdenv) document continuation
     in
     let max_steps = effective_max_steps host max_steps in
     let reasoning_request = effective_reasoning host reasoning_effort in
     let* ({ stop_dune; permission_of; _ } as runtime) =
       assemble ~sw ~stdenv ~json ~store ~session_id:id host ~mode ~model
         ~reasoning_request ~permission_mode ~sandbox ~max_steps
     in
     let* result =
       Fun.protect ~finally:stop_dune (fun () ->
           execution_terminal ~json ~stdenv ~store ~id ~started
             (match action with
             | Reply { id = permission; answer; message } ->
                 drive_goal ~stdenv ~store ~json
                   ~unattended:(effective_unattended host permission_unattended)
                   ~mode ~max_steps ~reasoning_request runtime document
                   (Spice_protocol.Command.Reply
                      { permission; answer; via = None; message })
             | Answer_question { pending; text } ->
                 drive_goal ~stdenv ~store ~json
                   ~unattended:(effective_unattended host permission_unattended)
                   ~mode ~max_steps ~reasoning_request runtime document
                   (Spice_protocol.Command.Answer
                      {
                        turn = pending.Session.Waiting.turn;
                        call_id = Tool_call.id pending.Session.Waiting.call;
                        text;
                      })
             | Finish { id; result } ->
                 drive_goal ~stdenv ~store ~json
                   ~unattended:(effective_unattended host permission_unattended)
                   ~mode ~max_steps ~reasoning_request runtime document
                   (Spice_protocol.Command.Finish_tool (id, result))))
     in
     print_changed_trailer ~json ~stdenv ~store result;
     Ok
       (print_result ~json ~permission_of
          ~duration_ms:(duration_ms ~started stdenv)
          result))

(* Goal lifecycle verbs are session-scoped continuations that mutate the goal
   artifact, not the session transcript. Pause, edit, and clear need no
   model or credentials; resume reactivates the goal and, on an idle session,
   starts pursuing it again. *)

let goal_reply json model reasoning_effort workflow_mode permission_mode
    permission_unattended sandbox max_steps cwd overrides last session_ref verb
    goal_budget =
  with_host ?cwd ~overrides @@ fun ~stdenv host ->
  let started = monotonic_now stdenv in
  Eio.Switch.run @@ fun sw ->
  status
    (let store = Host_session.store ~stdenv host in
     let* document =
       resolve_session_target ~command:"run reply" ~surface:`Headless ~stdenv
         host ~last session_ref
     in
     let session = Store.Document.session document in
     let id = Session.id session in
     let fs, root = goal_store_paths ~stdenv ~store in
     let verb_now = now stdenv in
     match verb with
     | `Pause ->
         let* goal =
           goal_verb_result
             (Goal_run.pause_goal ~fs ~root ~session:id ~now:verb_now)
         in
         print_goal_event ~json ~type_:"goal.paused" id goal;
         if not json then
           stderr_printf "spice: resume the goal with: %s\n"
             (goal_resume_invocation ~session:id);
         Ok Success
     | `Clear ->
         let* goal =
           goal_verb_result
             (Goal_run.clear_goal ~fs ~root ~session:id ~now:verb_now)
         in
         print_goal_event ~json ~type_:"goal.cleared" id goal;
         Ok Success
     | `Edit objective ->
         let* goal =
           goal_verb_result
             (Goal_run.edit_goal ~fs ~root ~session:id ~objective ~now:verb_now)
         in
         print_goal_event ~json ~type_:"goal.objective_updated" id goal;
         Ok Success
     | `Resume -> (
         let* mode =
           match workflow_mode with
           | Some (Spice_protocol.Mode.Plan | Spice_protocol.Mode.Review) ->
               usage "--resume-goal requires build mode"
           | Some Spice_protocol.Mode.Build | None ->
               Ok Spice_protocol.Mode.Build
         in
         let* () = validate_max_steps max_steps in
         let* goal =
           goal_verb_result
             (Goal_run.resume_goal ~fs ~root ~session:id
                ?token_budget:goal_budget ~now:verb_now ())
         in
         print_goal_event ~json ~type_:"goal.resumed" id goal;
         match Session.Run.phase session with
         | Session.Run.Phase.Active | Session.Run.Phase.Waiting _ ->
             (* A blocked or active turn keeps the driver's seat; continuation
                follows once that turn ends normally. *)
             if not json then
               stderr_printf
                 "spice: goal resumed; the session has an active or blocked \
                  turn, continuation follows once it ends\n";
             Ok Success
         | Session.Run.Phase.Idle ->
             let max_steps = effective_max_steps host max_steps in
             let reasoning_request =
               effective_reasoning host reasoning_effort
             in
             let* ({ model; stop_dune; permission_of; _ } as runtime) =
               assemble ~sw ~stdenv ~json ~store ~session_id:id host ~mode
                 ~model ~reasoning_request ~permission_mode ~sandbox ~max_steps
             in
             let turn =
               make_turn ~origin:Goal.turn_origin stdenv model mode
                 (Goal_run.continuation_prompt goal)
                 max_steps ~reasoning_request
             in
             let* result =
               Fun.protect ~finally:stop_dune (fun () ->
                   execution_terminal ~json ~stdenv ~store ~id ~started
                     (drive_goal ~stdenv ~store ~json
                        ~unattended:
                          (effective_unattended host permission_unattended)
                        ~mode ~max_steps ~reasoning_request runtime document
                        (Spice_protocol.Command.Start turn)))
             in
             print_changed_trailer ~json ~stdenv ~store result;
             Ok
               (print_result ~json ~permission_of
                  ~duration_ms:(duration_ms ~started stdenv)
                  result)))

(* Dispatch *)

let continuation approve_plan reject_plan allow allow_session deny deny_message
    question answer interrupt_tool tool_reason =
  let permission_replies =
    [
      Option.map
        (fun id ->
          Permission_reply
            {
              id;
              answer =
                Spice_permission.Policy.Review.Allow
                  Spice_permission.Policy.Review.Once;
              message = None;
            })
        allow;
      Option.map
        (fun id ->
          Permission_reply
            {
              id;
              answer =
                Spice_permission.Policy.Review.Allow
                  Spice_permission.Policy.Review.Session;
              message = None;
            })
        allow_session;
      Option.map
        (fun id ->
          Permission_reply
            {
              id;
              answer = Spice_permission.Policy.Review.Deny;
              message = deny_message;
            })
        deny;
    ]
    |> List.filter_map Fun.id
  in
  let* () =
    match (deny, reject_plan, deny_message) with
    | None, false, Some _ -> usage "--message requires --deny or --reject-plan"
    | _ -> Ok ()
  in
  (* A plan decision reuses [--message] for the rejection reason, mirroring
     [--deny --message]. It excludes every other continuation. *)
  let* plan_decision =
    match (approve_plan, reject_plan) with
    | true, true -> usage "choose only one of --approve-plan or --reject-plan"
    | true, false -> Ok (Some Spice_protocol.Plan.Decision.Approve)
    | false, true ->
        Ok
          (Some (Spice_protocol.Plan.Decision.Reject { reason = deny_message }))
    | false, false -> Ok None
  in
  let tool_continuation =
    Option.map
      (fun id -> Tool_claim_interrupted { id; reason = tool_reason })
      interrupt_tool
  in
  match plan_decision with
  | Some decision ->
      if
        (not (List.is_empty permission_replies))
        || Option.is_some question || Option.is_some answer
        || Option.is_some tool_continuation
      then usage "plan decision cannot be combined with another continuation"
      else Ok (Plan_decision decision)
  | None -> (
      match (permission_replies, question, answer, tool_continuation) with
      | [], None, None, None ->
          usage
            "reply requires a decision: --allow, --allow-session, --deny, \
             --question with --answer, --approve-plan, --reject-plan, or \
             --tool-interrupted; to advance a blocked session without one, use \
             `spice run resume SESSION`"
      | [], Some _, None, None -> usage "--question requires --answer"
      | [], None, Some _, None -> usage "--answer requires --question"
      | [], Some _, _, Some _ | [], None, Some _, Some _ ->
          usage "question continuation cannot be combined with tool recovery"
      | [], Some call_id, Some answer, None ->
          Ok (Question_answer { call_id; answer })
      | [], None, None, Some continuation -> Ok continuation
      | [ continuation ], None, None, None -> Ok continuation
      | [ _ ], _, _, _ ->
          usage
            "permission continuation cannot be combined with another \
             continuation"
      | _ :: _ :: _, _, _, _ ->
          usage "choose only one of --allow, --allow-session, or --deny")

(* Each verb owns its arguments, so the start/resume/reply exclusions that
   were once a flag-combination matrix are structural: [--id]/[--title]/
   [--ephemeral]/[--skill] exist only on [start], PROMPT only on [start] and
   [resume], and decisions only on [reply]. *)

let start_cli json raw_id title model reasoning_effort workflow_mode
    permission_mode permission_unattended sandbox ephemeral max_steps cwd
    overrides skill_names goal_objective goal_budget prompt extra =
  if Option.is_some extra then
    status (usage "run accepts a single PROMPT; quote prompts with spaces")
  else
    start json raw_id title model reasoning_effort workflow_mode permission_mode
      permission_unattended sandbox ephemeral max_steps cwd overrides
      skill_names goal_objective goal_budget prompt

let goal_verb_of_flags ~pause_goal ~resume_goal ~edit_goal ~clear_goal =
  match (pause_goal, resume_goal, edit_goal, clear_goal) with
  | false, false, None, false -> Ok None
  | true, false, None, false -> Ok (Some `Pause)
  | false, true, None, false -> Ok (Some `Resume)
  | false, false, Some objective, false -> Ok (Some (`Edit objective))
  | false, false, None, true -> Ok (Some `Clear)
  | _ ->
      usage
        "choose only one of --pause-goal, --resume-goal, --edit-goal, or \
         --clear-goal"

let reply_cli json model reasoning_effort workflow_mode permission_mode
    permission_unattended sandbox max_steps cwd overrides approve_plan
    reject_plan allow allow_session deny deny_message question answer
    interrupt_tool tool_reason pause_goal resume_goal edit_goal clear_goal
    goal_budget reply_last session_id =
  status
    (let* goal_verb =
       goal_verb_of_flags ~pause_goal ~resume_goal ~edit_goal ~clear_goal
     in
     let other_continuation =
       approve_plan || reject_plan || Option.is_some allow
       || Option.is_some allow_session
       || Option.is_some deny || Option.is_some question
       || Option.is_some answer
       || Option.is_some interrupt_tool
     in
     match goal_verb with
     | Some verb ->
         let* () =
           if other_continuation then
             usage "a goal verb cannot be combined with another continuation"
           else Ok ()
         in
         let* () =
           match (verb, goal_budget) with
           | `Resume, _ | _, None -> Ok ()
           | _, Some _ -> usage "--goal-budget requires --resume-goal"
         in
         Ok
           (goal_reply json model reasoning_effort workflow_mode permission_mode
              permission_unattended sandbox max_steps cwd overrides reply_last
              session_id verb goal_budget)
     | None ->
         let* () =
           match goal_budget with
           | Some _ -> usage "--goal-budget requires --resume-goal"
           | None -> Ok ()
         in
         let* answer =
           match answer with
           | None -> Ok None
           | Some raw -> Result.map Option.some (read_answer (Some raw))
         in
         let* deny_message = read_deny_message deny_message in
         let* tool_reason =
           match (interrupt_tool, tool_reason) with
           | None, Some _ -> usage "--reason requires --tool-interrupted"
           | None, None -> read_tool_interrupted_reason None
           | Some _, reason -> read_tool_interrupted_reason reason
         in
         let* continuation =
           continuation approve_plan reject_plan allow allow_session deny
             deny_message question answer interrupt_tool tool_reason
         in
         Ok
           (continue json model reasoning_effort workflow_mode permission_mode
              permission_unattended sandbox max_steps cwd overrides reply_last
              session_id continuation))

(* Command line *)

let json = Cli_arg.json_flag ~doc:"Print JSONL execution events." ()

let id =
  Arg.(
    value
    & opt (some Cli_arg.session_id) None
    & info [ "id" ] ~docv:"ID" ~doc:"New session id.")

let approve_plan =
  Arg.(
    value & flag
    & info [ "approve-plan" ]
        ~doc:"Approve the pending plan proposal, then continue the turn.")

let reject_plan =
  Arg.(
    value & flag
    & info [ "reject-plan" ]
        ~doc:
          "Reject the pending plan proposal so the model can revise it; the \
           reason rides $(b,--message).")

let allow =
  Arg.(
    value
    & opt (some Cli_arg.session_permission_id) None
    & info [ "allow" ] ~docv:"PERMISSION_ID"
        ~doc:"Allow a pending permission once.")

let skill_names =
  Arg.(
    value & opt_all string []
    & info [ "skill" ] ~docs:Cli_common.s_context_options ~docv:"NAME"
        ~doc:
          "Load the named skill into the turn ahead of the prompt. Repeatable.")

let allow_session =
  Arg.(
    value
    & opt (some Cli_arg.session_permission_id) None
    & info [ "allow-session" ] ~docv:"PERMISSION_ID"
        ~doc:"Allow a pending permission for this session.")

let deny =
  Arg.(
    value
    & opt (some Cli_arg.session_permission_id) None
    & info [ "deny" ] ~docv:"PERMISSION_ID" ~doc:"Deny a pending permission.")

let deny_message =
  Arg.(
    value
    & opt (some string) None
    & info [ "message" ] ~docv:"TEXT"
        ~doc:
          "Model-visible feedback for $(b,--deny) or $(b,--reject-plan), or - \
           to read stdin.")

let question =
  Arg.(
    value
    & opt (some string) None
    & info [ "question" ] ~docv:"CALL_ID" ~doc:"Answer a pending ask_user call.")

let answer =
  Arg.(
    value
    & opt (some string) None
    & info [ "answer" ] ~docv:"TEXT" ~doc:"Answer text, or - to read stdin.")

let interrupt_tool =
  Arg.(
    value
    & opt (some Cli_arg.session_tool_claim_id) None
    & info [ "tool-interrupted" ] ~docv:"EXECUTION_ID"
        ~doc:"Mark a pending unfinished tool claim as interrupted.")

let tool_reason =
  Arg.(
    value
    & opt (some string) None
    & info [ "reason" ] ~docv:"TEXT"
        ~doc:"Tool interruption reason, or - to read stdin.")

let title =
  Arg.(
    value
    & opt (some string) None
    & info [ "title" ] ~docv:"TITLE" ~doc:"New session title.")

let model =
  Cli_arg.model_opt
    ~doc:"Provider/model selector for this run, as $(b,provider/model)." ()

let reasoning =
  let module Effort = Spice_llm.Request.Options.Reasoning_effort in
  let efforts =
    List.map (fun effort -> (Effort.to_string effort, effort)) Effort.all
  in
  Arg.(
    value
    & opt (some (enum efforts)) None
    & info [ "reasoning" ] ~docv:"EFFORT"
        ~doc:
          "Reasoning effort for this run: $(b,none), $(b,minimal), $(b,low), \
           $(b,medium), $(b,high), $(b,xhigh), or $(b,max). The selected model \
           must support it; see $(b,spice models show).")

let permission_mode =
  let parse raw =
    match Spice_host.Permission.Preset.of_string raw with
    | Some mode -> Ok mode
    | None -> Error (`Msg ("unknown permission mode: " ^ raw))
  in
  let print = Spice_host.Permission.Preset.pp in
  Arg.(
    value
    & opt (some (conv (parse, print))) None
    & info
        [ "permission"; "permission-mode" ]
        ~docs:Cli_common.s_sandbox_options ~docv:"MODE"
        ~doc:"Permission preset override.")

let permission_unattended =
  let parse raw =
    match Spice_host.Permission.Unattended.of_string raw with
    | Some unattended -> Ok unattended
    | None -> Error (`Msg ("unknown unattended permission policy: " ^ raw))
  in
  let print = Spice_host.Permission.Unattended.pp in
  Arg.(
    value
    & opt (some (conv (parse, print))) None
    & info
        [ "permission-unattended" ]
        ~docs:Cli_common.s_sandbox_options ~docv:"POLICY"
        ~doc:
          "What to do when a permission review is needed: $(b,block) parks the \
           session as a resumable waiting and exits with the blocked code; \
           $(b,deny) records an unattended denial with model-visible feedback \
           and lets the run continue. Overrides $(b,permission.unattended) \
           config for this invocation.")

let sandbox =
  let modes =
    List.map
      (fun mode -> (Spice_host.Sandbox.Mode.to_string mode, mode))
      Spice_host.Sandbox.Mode.all
  in
  let mode =
    Arg.(
      value
      & opt (some (enum modes)) None
      & info [ "sandbox" ] ~docs:Cli_common.s_sandbox_options ~docv:"MODE"
          ~doc:
            "Sandbox mode for this run: $(b,read-only), $(b,workspace-write), \
             $(b,danger-full-access), or $(b,external-sandbox). When absent, \
             $(b,sandbox.mode) config applies; without that, Spice uses \
             $(b,workspace-write). Restricted modes are requirements: they \
             fail closed when no backend can enforce them. \
             $(b,danger-full-access) runs commands without confinement; \
             $(b,external-sandbox) declares that Spice already runs inside an \
             external isolation boundary.")
  in
  let require =
    Arg.(
      value & flag
      & info [ "require-sandbox" ] ~docs:Cli_common.s_sandbox_options
          ~doc:
            "Fail before provider credentials and session creation unless the \
             restricted sandbox is enforceable by a real backend, regardless \
             of $(b,sandbox.require) config.")
  in
  Term.(
    const (fun sandbox_flag require_sandbox ->
        { Cli_common.sandbox_flag; require_sandbox })
    $ mode $ require)

let ephemeral =
  Arg.(
    value & flag
    & info [ "ephemeral" ]
        ~doc:
          "Do not persist the session: store it under a throwaway root removed \
           when the run ends. One-shot scripted calls leave nothing in the \
           session store; blocked ephemeral sessions are discarded and cannot \
           be resumed.")

let workflow_mode =
  let parse raw =
    match Spice_protocol.Mode.of_string raw with
    | Ok mode -> Ok mode
    | Error { Spice_protocol.Mode.input; candidates } ->
        Error
          (`Msg
             (Spice_diagnostic.to_string
                (Spice_diagnostic.make
                   ~hints:(Spice_diagnostic.did_you_mean input ~candidates)
                   ("unknown workflow mode: " ^ input))))
  in
  Arg.(
    value
    & opt (some (conv (parse, Spice_protocol.Mode.pp))) None
    & info [ "mode" ] ~docv:"MODE" ~doc:"Workflow mode: build, plan, or review.")

let max_steps =
  Arg.(
    value
    & opt (some int) None
    & info [ "max-steps" ] ~docv:"N" ~doc:"Maximum model/tool steps.")

let cwd = Cli_arg.cwd ()

let goal_objective =
  Arg.(
    value
    & opt (some string) None
    & info [ "goal" ] ~docv:"TEXT"
        ~doc:
          "Set a session goal and pursue it across turns until it is complete, \
           blocked, or stopped. Build mode only. Without PROMPT the goal text \
           seeds the first turn.")

let goal_budget =
  Arg.(
    value
    & opt (some int) None
    & info [ "goal-budget" ] ~docv:"TOKENS"
        ~doc:
          "Token budget for the goal; the run stops as budget-limited when \
           reached. Requires $(b,--goal) or $(b,--resume-goal).")

let pause_goal =
  Arg.(
    value & flag
    & info [ "pause-goal" ]
        ~doc:"Pause the session's active goal; no turn is started.")

let resume_goal =
  Arg.(
    value & flag
    & info [ "resume-goal" ]
        ~doc:
          "Reactivate a paused, blocked, or budget-limited goal and resume \
           pursuing it when the session is idle.")

let edit_goal =
  Arg.(
    value
    & opt (some string) None
    & info [ "edit-goal" ] ~docv:"TEXT"
        ~doc:"Replace the unfinished goal's objective in place.")

let clear_goal =
  Arg.(
    value & flag
    & info [ "clear-goal" ] ~doc:"Clear the session's unfinished goal.")

let prompt =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"Prompt text, or - to read stdin.")

let extra =
  Arg.(
    value
    & pos 1 (some string) None
    & info [] ~docv:"EXTRA" ~doc:"Unexpected extra argument.")

let parse_session_id raw =
  match Session.Id.of_string raw with
  | id -> Ok id
  | exception Invalid_argument message -> usage message

let resume_cli json last model reasoning_effort workflow_mode permission_mode
    permission_unattended sandbox max_steps cwd overrides first second =
  if last then
    match second with
    | Some _ -> status (usage "run resume --last accepts at most one PROMPT")
    | None ->
        with_host ?cwd ~overrides @@ fun ~stdenv host ->
        status
          (let* id = newest_session_in_cwd ~surface:`Headless ~stdenv host in
           Ok
             (resume_in_host ~stdenv host json model reasoning_effort
                workflow_mode permission_mode permission_unattended sandbox
                max_steps id first))
  else
    match (first, second) with
    | None, _ ->
        status
          (usage
             "run resume requires SESSION or --last; run `spice session list` \
              or `spice run resume --last`")
    | Some raw_id, prompt ->
        status
          (let* id = parse_session_id raw_id in
           Ok
             (resume json model reasoning_effort workflow_mode permission_mode
                permission_unattended sandbox max_steps cwd overrides id prompt))

let last = Cli_arg.last_flag ~doc:"Resume the newest session in this cwd." ()

let resume_first =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"SESSION_OR_PROMPT"
        ~doc:"Session id, or prompt when --last is set.")

let resume_second =
  Arg.(
    value
    & pos 1 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"Prompt text.")

let reply_session =
  Cli_arg.session_pos ~doc:"Blocked session id or unique prefix." ()

let reply_last =
  Cli_arg.last_flag ~doc:"Reply to the newest session in this cwd." ()

(* Commands *)

let start_term =
  Term.(
    const start_cli $ json $ id $ title $ model $ reasoning $ workflow_mode
    $ permission_mode $ permission_unattended $ sandbox $ ephemeral $ max_steps
    $ cwd $ Cli_arg.run_overrides $ skill_names $ goal_objective $ goal_budget
    $ prompt $ extra)

let start_command =
  let man =
    [
      `S Cmdliner.Manpage.s_description;
      `P
        "Starts a new headless session in the current workspace and runs one \
         turn until it finishes or blocks on a decision. A blocked run exits \
         with code 3 and prints the $(b,spice run reply) invocations that feed \
         the decision back in.";
      `P
        "$(b,spice run) $(i,PROMPT) without a subcommand is shorthand for this \
         command.";
      `S Cmdliner.Manpage.s_examples;
      `Pre "  spice run \"add unit tests for Foo.parse\"";
      `Pre "  git diff | spice run - --json";
      `Pre "  spice run --ephemeral \"summarize TODO.md\"";
    ]
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Start a new headless session." ~man ~exits)
    (exit_term start_term)

let resume_term =
  Term.(
    const resume_cli $ json $ last $ model $ reasoning $ workflow_mode
    $ permission_mode $ permission_unattended $ sandbox $ max_steps $ cwd
    $ Cli_arg.run_overrides $ resume_first $ resume_second)

let resume_command =
  let man =
    [
      `S Cmdliner.Manpage.s_description;
      `P
        "Advances a saved session headlessly: with $(i,PROMPT), starts a new \
         turn; without it, resumes the session's blocked or interrupted turn. \
         $(b,--last) selects the newest session in the current working \
         directory. To resume a session in the interactive TUI, use $(b,spice \
         resume) instead.";
      `S Cmdliner.Manpage.s_examples;
      `Pre "  spice run resume ses_123 \"now add error handling\"";
      `Pre "  spice run resume --last";
    ]
  in
  Cmd.v
    (Cmd.info "resume" ~doc:"Resume or extend a saved session headlessly." ~man
       ~exits)
    (exit_term resume_term)

let reply_term =
  Term.(
    const reply_cli $ json $ model $ reasoning $ workflow_mode $ permission_mode
    $ permission_unattended $ sandbox $ max_steps $ cwd $ Cli_arg.run_overrides
    $ approve_plan $ reject_plan $ allow $ allow_session $ deny $ deny_message
    $ question $ answer $ interrupt_tool $ tool_reason $ pause_goal
    $ resume_goal $ edit_goal $ clear_goal $ goal_budget $ reply_last
    $ reply_session)

let reply_command =
  let man =
    [
      `S Cmdliner.Manpage.s_description;
      `P
        "Feeds one decision into a blocked session and continues the turn: a \
         permission review ($(b,--allow), $(b,--allow-session), $(b,--deny)), \
         an answer to a model question ($(b,--question) with $(b,--answer)), a \
         plan decision ($(b,--approve-plan), $(b,--reject-plan)), or an \
         interrupted-tool recovery ($(b,--tool-interrupted)). A blocked \
         $(b,spice run) prints these invocations ready to copy.";
      `S Cmdliner.Manpage.s_examples;
      `Pre "  spice run reply ses_123 --allow perm_1";
      `Pre
        "  spice run reply ses_123 --deny perm_1 --message \"use rg instead\"";
      `Pre "  spice run reply ses_123 --question call_7 --answer \"yes\"";
      `Pre "  spice run reply ses_123 --approve-plan";
    ]
  in
  Cmd.v
    (Cmd.info "reply" ~doc:"Feed a decision into a blocked session." ~man ~exits)
    (exit_term reply_term)

let group =
  let man =
    [
      `S Cmdliner.Manpage.s_description;
      `P
        "Runs headless sessions: the agent plans, edits, and runs tools in the \
         workspace without the interactive TUI, printing progress to stdout \
         and exiting when the turn finishes or blocks on a decision.";
      `P
        "$(b,spice run) $(i,PROMPT) starts a new session and is shorthand for \
         $(b,spice run start) $(i,PROMPT). A subcommand must be the first \
         argument after $(b,run); a prompt that collides with a subcommand \
         name can be passed after $(b,--).";
      `S Cmdliner.Manpage.s_examples;
      `Pre "  spice run \"add unit tests for Foo.parse\"";
      `Pre "  spice run resume --last \"address the review comments\"";
      `Pre "  spice run reply ses_123 --allow perm_1";
    ]
  in
  let envs =
    [
      Cmd.Env.info "SPICE_AUTO_TITLE"
        ~doc:"If set to $(b,0), skip generating a session title after the run.";
      Cmd.Env.info "SPICE_DEBUG"
        ~doc:
          "If set to $(b,1), print diagnostics for best-effort housekeeping \
           such as automatic session titling.";
    ]
  in
  Cmd.group ~default:(exit_term start_term)
    (Cmd.info "run" ~doc:"Run headless sessions."
       ~docs:Cli_common.s_run_commands ~man ~envs ~exits)
    [ start_command; resume_command; reply_command ]
