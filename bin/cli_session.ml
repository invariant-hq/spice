(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Cli_common
open Result.Syntax
module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
module Host_session = Spice_host.Session
module Session = Spice_session
module Store = Spice_session_store
module Term = Cmdliner.Term
module Tool_call = Spice_llm.Tool.Call

let status_string = function
  | Session.Metadata.Status.Active -> "active"
  | Session.Metadata.Status.Archived -> "archived"
  | Session.Metadata.Status.Deleted -> "deleted"

let id_string id = Session.Id.to_string id
let turn_id_string id = Session.Turn.Id.to_string id
let time_json time = json_encode Session.Time.jsont time

let workflow_root host =
  Spice_host.Config.store_root (Spice_host.Host.config host)
  |> Spice_path.Abs.to_string

let default_limit = 25

module Summary = struct
  include Spice_protocol.Session_summary

  let id t = t.id
  let title t = t.title
  let preview t = t.preview
  let lifecycle t = t.lifecycle
  let phase t = t.phase
  let event_count t = t.event_count
  let active_turn t = t.active_turn
  let cwd t = t.cwd
  let forked_from t = t.forked_from
  let created_at t = t.created_at
  let updated_at t = t.updated_at

  let revision t =
    match t.revision with
    | Some revision -> revision
    | None ->
        invalid_arg "Cli_session.Summary.revision: summary has no revision"
end

let load_workflow ~stdenv host session_id =
  let fs = Eio.Stdenv.fs stdenv in
  let root = workflow_root host in
  let* plans =
    sidecar (Spice_host.Artifacts.Plan.list ~fs ~root ~session:session_id ())
  in
  let* todos = sidecar (Spice_host.Artifacts.Todo.load ~fs ~root session_id) in
  let* goal = sidecar (Spice_host.Artifacts.Goal.load ~fs ~root session_id) in
  let* subagents =
    sidecar
      (Spice_host.Artifacts.Subagent_run.list ~fs ~root ~parent:session_id)
  in
  (* Terminal goals project as absent: the goal surface shows what the
     session is pursuing, not history. *)
  let goal =
    match goal with
    | Some goal when Spice_protocol.Goal.is_unfinished goal -> Some goal
    | Some _ | None -> None
  in
  Ok (plans, todos, goal, subagents)

let workflow_show_json plans todos goal subagents =
  json_obj
    ([
       ( "plans",
         json_list (List.map (json_encode Spice_protocol.Plan.jsont) plans) );
       ("todos", json_encode Spice_protocol.Todo.jsont todos);
     ]
    @ (match goal with
      | None -> []
      | Some goal -> [ ("goal", json_encode Spice_protocol.Goal.jsont goal) ])
    @ [
        ( "subagents",
          json_list
            (List.map (json_encode Spice_protocol.Subagent_run.jsont) subagents)
        );
      ])

let workflow_is_empty plans todos goal subagents =
  List.is_empty plans
  && List.is_empty (Spice_protocol.Todo.items todos)
  && Option.is_none goal && List.is_empty subagents

let workflow_show_field plans todos goal subagents =
  if workflow_is_empty plans todos goal subagents then []
  else [ ("workflow", workflow_show_json plans todos goal subagents) ]

let fork_json = function
  | None -> json_null
  | Some fork ->
      json_obj
        [
          ( "parent",
            Jsont.Json.string
              (id_string (Session.Metadata.Forked_from.parent fork)) );
          ( "copied_events",
            Jsont.Json.int (Session.Metadata.Forked_from.copied_events fork) );
        ]

let active_turn_json = function
  | None -> json_null
  | Some turn -> Jsont.Json.string (Session.Turn.Id.to_string turn)

let workflow_mode_field state active_turn =
  match active_turn with
  | None -> []
  | Some turn_id -> (
      match Session.State.turn turn_id state with
      | None -> []
      | Some turn -> (
          match Session.Turn.mode turn with
          | None -> []
          | Some mode -> [ ("workflow_mode", Jsont.Json.string mode) ]))

let list_item_fields item =
  [
    ("id", Jsont.Json.string (id_string (Summary.id item)));
    ("title", json_null_or_string (Summary.title item));
    ("preview", json_null_or_string (Summary.preview item));
    ("lifecycle", Jsont.Json.string (status_string (Summary.lifecycle item)));
    ( "phase",
      Jsont.Json.string (Session.Run.Phase.to_string (Summary.phase item)) );
    ("forked_from", fork_json (Summary.forked_from item));
    ("event_count", Jsont.Json.int (Summary.event_count item));
    ("active_turn", active_turn_json (Summary.active_turn item));
    ("cwd", Jsont.Json.string (Spice_path.Abs.to_string (Summary.cwd item)));
    ("created_at", time_json (Summary.created_at item));
    ("updated_at", time_json (Summary.updated_at item));
    ( "revision",
      Jsont.Json.string (Session.Revision.to_string (Summary.revision item)) );
  ]

let list_item_json item = json_obj (list_item_fields item)

let corrupt_json corrupt =
  json_obj
    [
      ( "id",
        match Store.Corrupt.id corrupt with
        | None -> json_null
        | Some id -> Jsont.Json.string (id_string id) );
      ("path", Jsont.Json.string (Store.Corrupt.path corrupt));
      ("message", Jsont.Json.string (Store.Corrupt.message corrupt));
    ]

let corrupt_field corrupt =
  match corrupt with
  | [] -> []
  | corrupt -> [ ("corrupt", json_list (List.map corrupt_json corrupt)) ]

(* Compaction and context-pressure projections shared by status and show.
   Status reports summary presence only; show is the inspection surface and
   includes the full latest summary text. *)

let model_string model = Format.asprintf "%a" Spice_llm.Model.pp model

let latest_compaction_json ~summary state =
  match Session.State.latest_compaction state with
  | None -> json_null
  | Some compaction ->
      let tokens_estimate =
        match Session.Compaction.tokens compaction with
        | None -> json_null
        | Some tokens ->
            json_obj
              [
                ( "before",
                  json_null_or_int
                    (Session.Compaction.Token_estimate.before tokens) );
                ( "after",
                  json_null_or_int
                    (Session.Compaction.Token_estimate.after tokens) );
                ( "summary_input",
                  json_null_or_int
                    (Session.Compaction.Token_estimate.summary_input tokens) );
                ( "summary_output",
                  json_null_or_int
                    (Session.Compaction.Token_estimate.summary_output tokens) );
              ]
      in
      let range = Session.Compaction.range compaction in
      json_obj
        ([
           ( "reason",
             Jsont.Json.string
               (Session.Compaction.Reason.to_string
                  (Session.Compaction.reason compaction)) );
           ( "model",
             json_null_or_string
               (Option.map model_string (Session.Compaction.model compaction))
           );
           ( "summary_present",
             Jsont.Json.bool
               (not (String.is_empty (Session.Compaction.summary compaction)))
           );
           ("tokens_estimate", tokens_estimate);
           ( "summarized_messages",
             json_null_or_int
               (Option.map Session.Compaction.Range.summarized_messages range)
           );
           ( "retained_tail_messages",
             json_null_or_int
               (Option.map Session.Compaction.Range.retained_tail_messages range)
           );
         ]
        @
        if summary then
          [
            ( "summary",
              Jsont.Json.string (Session.Compaction.summary compaction) );
          ]
        else [])

(* The session's latest model, resolved against the static provider catalog:
   declared facts only, no role heuristics, no auth readiness. A model absent
   from the catalog yields null window/limit. *)
let catalog_model catalog state =
  Option.bind (Session.State.latest_model state) (fun llm ->
      Option.bind
        (Spice_provider.Catalog.provider catalog (Spice_llm.Model.provider llm))
        (fun provider -> Spice_provider.model provider llm))

let context_json ~catalog state =
  let model = catalog_model catalog state in
  let pressure = Spice_host.Compactor.Pressure.of_state state in
  json_obj
    [
      ( "projected_input_tokens_estimate",
        Jsont.Json.int (Spice_host.Compactor.Pressure.projected_input pressure)
      );
      ( "basis",
        Jsont.Json.string
          (match Spice_host.Compactor.Pressure.basis pressure with
          | Spice_protocol.Event.Usage -> "usage"
          | Spice_protocol.Event.Estimate -> "estimate") );
      ( "context_window",
        json_null_or_int (Option.bind model Spice_provider.Model.context_window)
      );
      ( "auto_compaction_limit",
        json_null_or_int
          (Option.bind model Spice_host.Compactor.Policy.auto_limit_of_model) );
    ]

(* The one human spelling of a compaction's range, shared by status and the
   manual compact result line. *)
let compaction_range_suffix compaction =
  match Session.Compaction.range compaction with
  | None -> ""
  | Some range ->
      Printf.sprintf " summarized=%d retained=%d"
        (Session.Compaction.Range.summarized_messages range)
        (Session.Compaction.Range.retained_tail_messages range)

let compaction_fields ~summary ~catalog state =
  [
    ("latest_compaction", latest_compaction_json ~summary state);
    ("context", context_json ~catalog state);
  ]

let now_for_render stdenv =
  match Sys.getenv_opt "SPICE_NOW" with
  | Some raw -> (
      match Int64.of_string_opt raw with
      | Some ms -> Session.Time.of_unix_ms ms
      | None ->
          Eio.Time.now (Eio.Stdenv.clock stdenv)
          |> Session.Time.of_unix_seconds_float)
  | None ->
      Eio.Time.now (Eio.Stdenv.clock stdenv)
      |> Session.Time.of_unix_seconds_float

let age ~now time =
  let delta_ms =
    Int64.sub (Session.Time.to_unix_ms now) (Session.Time.to_unix_ms time)
    |> max 0L
  in
  let seconds = Int64.to_int (Int64.div delta_ms 1000L) in
  if seconds < 60 then "just now"
  else
    let minutes = seconds / 60 in
    if minutes < 60 then string_of_int minutes ^ "m ago"
    else
      let hours = minutes / 60 in
      if hours < 24 then string_of_int hours ^ "h ago"
      else string_of_int (hours / 24) ^ "d ago"

(* Row columns: ID PHASE [LIFECYCLE] AGE [CWD] TITLE. The lifecycle column
   appears only when --archived/--deleted widen the scope, so tombstoned rows
   are never rendered as ordinary idle sessions; CWD appears only with --all. *)
let item_row ~show_lifecycle ~show_cwd ~id ~phase ~lifecycle ~age:age_text ~cwd
    ~title =
  [ id; phase ]
  @ (if show_lifecycle then [ lifecycle ] else [])
  @ [ age_text ]
  @ (if show_cwd then [ cwd ] else [])
  @ [ title ]

let item_cells ~now ~show_lifecycle ~show_cwd item =
  let title =
    Summary.title item
    |> Option.value
         ~default:
           (Option.value (Summary.preview item)
              ~default:(id_string (Summary.id item)))
  in
  item_row ~show_lifecycle ~show_cwd
    ~id:(id_string (Summary.id item))
    ~phase:(Session.Run.Phase.to_string (Summary.phase item))
    ~lifecycle:(status_string (Summary.lifecycle item))
    ~age:(age ~now (Summary.updated_at item))
    ~cwd:(Spice_path.Abs.to_string (Summary.cwd item))
    ~title

let print_items ~now ~show_lifecycle ~show_cwd items =
  print_table
    ~header:
      (item_row ~show_lifecycle ~show_cwd ~id:"ID" ~phase:"PHASE"
         ~lifecycle:"LIFECYCLE" ~age:"AGE" ~cwd:"CWD" ~title:"TITLE")
    (List.map (item_cells ~now ~show_lifecycle ~show_cwd) items)

let store stdenv host = Host_session.store ~stdenv host

let resolve_target ~command ~stdenv host last session =
  resolve_session_target ~command ~surface:`Headless ~stdenv host ~last session

let print_versioned_json type_ fields =
  stdout_printf "%s\n" (json_string (json_envelope ~type_ fields))

let create json raw_id title =
  with_host @@ fun ~stdenv host ->
  status
    (let* () = validate_title title in
     let id =
       match raw_id with
       | Some id -> id
       | None ->
           let stamp =
             Eio.Time.now (Eio.Stdenv.clock stdenv)
             |> Int64.bits_of_float |> Int64.to_string
           in
           Session.Id.of_string ("ses-" ^ stamp)
     in
     let store = store stdenv host in
     let* cwd = assembly (host_cwd host) in
     let* document =
       execution
         (Host_session.create ~store ~id ?title ~cwd ~created_at:(now stdenv) ())
     in
     if json then
       print_versioned_json "session"
         [ ("session", list_item_json (Host_session.of_document document)) ]
     else stdout_printf "%s\n" (id_string id);
     Ok Success)

let normalized_limit = function
  | None -> Ok (Some default_limit)
  | Some 0 -> Ok None
  | Some limit when limit > 0 -> Ok (Some limit)
  | Some limit ->
      usage ("session list limit must be positive: " ^ string_of_int limit)

let overfetch_limit = function None -> None | Some limit -> Some (limit + 1)

let split_truncated limit items =
  match limit with
  | None -> (items, false)
  | Some limit ->
      (List.take limit items, List.compare_length_with items limit > 0)

let list json all include_archived include_deleted limit =
  with_host @@ fun ~stdenv host ->
  status
    (let* limit = normalized_limit limit in
     let store = store stdenv host in
     let* cwd = assembly (host_cwd host) in
     let filter = if all then None else Some (in_cwd cwd) in
     let* documents, corrupt =
       session_store
         (Store.list store ~include_archived ~include_deleted ?filter
            ?limit:(overfetch_limit limit) ())
     in
     warn_corrupt corrupt;
     let items, truncated =
       documents |> List.map Host_session.of_document |> split_truncated limit
     in
     if json then
       print_versioned_json "sessions"
         ([ ("sessions", json_list (List.map list_item_json items)) ]
         @ corrupt_field corrupt)
     else (
       print_items ~now:(now_for_render stdenv)
         ~show_lifecycle:(include_archived || include_deleted)
         ~show_cwd:all items;
       if truncated then
         stderr_printf
           "spice: session list truncated; use --limit 0 to show all\n");
     Ok Success)

let active_model_string state =
  match Session.State.active_turn state with
  | None -> None
  | Some turn -> (
      match Session.State.turn turn state with
      | None -> None
      | Some turn ->
          Some
            (Format.asprintf "%a" Spice_llm.Model.pp (Session.Turn.model turn)))

let last_outcome_string state =
  Session.State.turns state |> List.rev
  |> List.find_map (fun turn ->
      Session.State.turn_outcome (Session.Turn.id turn) state)
  |> Option.map Cli_block.outcome_string

(* Render under the policy the blocked turn actually runs with: the rule
   table plus the active turn's workflow-mode contract. Unknown stored modes
   degrade to the default rather than failing a render. *)
let session_permission_context host session =
  let workflow_mode =
    let state = Session.state session in
    match Session.State.active_turn state with
    | None -> Spice_protocol.Mode.default
    | Some turn_id -> (
        match Session.State.turn turn_id state with
        | None -> Spice_protocol.Mode.default
        | Some turn -> Spice_protocol.Mode.of_turn turn)
  in
  Cli_block.permission_context (permission_args host None) ~workflow_mode

let execution_fields ~permission_of session phase =
  let state = Session.state session in
  [
    ("active_model", json_null_or_string (active_model_string state));
    ("last_outcome", json_null_or_string (last_outcome_string state));
    ( "waiting",
      match phase with
      | Cli_block.Waiting block ->
          Cli_block.json ~permission:(permission_of state) block
      | Cli_block.Idle | Cli_block.Active -> json_null );
  ]
  @ workflow_mode_field state (Session.State.active_turn state)

let show json last id =
  with_host @@ fun ~stdenv host ->
  status
    (let resolved =
       resolve_target ~command:"session show" ~stdenv host last id
     in
     (* A corrupt target still answers with a structured envelope so scripts
        never parse the stderr diagnostic; the command then fails through the
        ordinary store-error path. The envelope carries the concise first
        diagnostic line; the full decoder trace stays on stderr. *)
     (match resolved with
     | Error (`Session_store (_, Store.Error.Corrupt { path; message }))
       when json ->
         let message =
           match String.split_first ~sep:"\n" message with
           | Some (line, _) -> line
           | None -> message
         in
         print_versioned_json "session"
           [
             ( "session",
               json_obj
                 [
                   ( "id",
                     Jsont.Json.string
                       (match id with Some id -> id_string id | None -> "-") );
                   ("phase", Jsont.Json.string "error");
                   ("path", Jsont.Json.string path);
                   ("message", Jsont.Json.string message);
                 ] );
           ]
     | _ -> ());
     let* document = resolved in
     let session = Store.Document.session document in
     let item = Host_session.of_document document in
     let phase = Cli_block.phase session in
     let permission_of = session_permission_context host session in
     if json then (
       let* plans, todos, goal, subagents =
         load_workflow ~stdenv host (Session.id session)
       in
       print_versioned_json "session"
         (( "session",
            json_obj
              (list_item_fields item
              @ execution_fields ~permission_of session phase) )
          :: compaction_fields ~summary:true
               ~catalog:(Spice_host.Host.catalog host)
               (Session.state session)
         @ workflow_show_field plans todos goal subagents);
       Ok Success)
     else (
       stdout_printf "id: %s\n" (id_string (Summary.id item));
       stdout_printf "title: %s\n"
         (Option.value (Summary.title item) ~default:"-");
       stdout_printf "preview: %s\n"
         (Option.value (Summary.preview item) ~default:"-");
       stdout_printf "lifecycle: %s\n" (status_string (Summary.lifecycle item));
       stdout_printf "phase: %s\n"
         (Session.Run.Phase.to_string (Summary.phase item));
       stdout_printf "events: %d\n" (Summary.event_count item);
       (match Summary.forked_from item with
       | None -> stdout_printf "forked_from: -\n"
       | Some fork ->
           stdout_printf "forked_from: %s events=%d\n"
             (id_string (Session.Metadata.Forked_from.parent fork))
             (Session.Metadata.Forked_from.copied_events fork));
       stdout_printf "cwd: %s\n" (Spice_path.Abs.to_string (Summary.cwd item));
       stdout_printf "created_at: %Ld\n"
         (Session.Time.to_unix_ms (Summary.created_at item));
       stdout_printf "updated_at: %Ld\n"
         (Session.Time.to_unix_ms (Summary.updated_at item));
       stdout_printf "revision: %s\n"
         (Session.Revision.to_string (Summary.revision item));
       (match
          Spice_host.Artifacts.Goal.load ~fs:(Eio.Stdenv.fs stdenv)
            ~root:(workflow_root host) (Session.id session)
        with
       | Ok (Some goal) when Spice_protocol.Goal.is_unfinished goal ->
           stdout_printf "goal: %s — %s%s\n"
             (Spice_protocol.Goal.Status.to_string
                (Spice_protocol.Goal.status goal))
             (Spice_protocol.Goal.objective goal)
             (match Spice_protocol.Goal.token_budget goal with
             | None -> ""
             | Some budget ->
                 Printf.sprintf " (tokens %d/%d)"
                   (Spice_protocol.Goal.tokens_used goal)
                   budget)
       | Ok _ | Error _ -> ());
       (match Session.State.latest_compaction (Session.state session) with
       | None -> ()
       | Some compaction ->
           stdout_printf "latest_compaction: %s%s\n"
             (Session.Compaction.Reason.to_string
                (Session.Compaction.reason compaction))
             (compaction_range_suffix compaction));
       (* Next-step guidance prints only when the session can actually take
          that step: continuation commands for active waits, a restore hint
          for archived ones, nothing for terminal deleted tombstones. *)
       let print_hints hints = List.iter (stdout_printf "%s\n") hints in
       let print_permission_detail block =
         match block with
         | Session.Waiting.Permission request ->
             print_hints
               (Cli_block.permission_lines
                  (permission_of (Session.state session))
                  request)
         | Session.Waiting.Host_tool _ | Session.Waiting.Tool_claim _ -> ()
       in
       let restore_hint =
         "restore first: spice session restore "
         ^ shell_arg (id_string (Session.id session))
       in
       (match (phase, Summary.lifecycle item) with
       | Cli_block.Idle, _ -> ()
       | Cli_block.Waiting block, Session.Metadata.Status.Active ->
           stdout_printf "%s\n" (Cli_block.human block);
           print_permission_detail block;
           print_hints (Cli_block.commands ~session:(Session.id session) block)
       | Cli_block.Waiting block, Session.Metadata.Status.Archived ->
           stdout_printf "%s\n" (Cli_block.human block);
           print_hints [ restore_hint ]
       | Cli_block.Waiting block, Session.Metadata.Status.Deleted ->
           stdout_printf "%s\n" (Cli_block.human block)
       | Cli_block.Active, lifecycle -> (
           let turn =
             Session.State.active_turn (Session.state session)
             |> Option.map turn_id_string |> Option.value ~default:"-"
           in
           stdout_printf "active turn %s has no live owner\n" turn;
           match lifecycle with
           | Session.Metadata.Status.Active ->
               print_hints
                 [ Cli_block.resume_command ~session:(Session.id session) ]
           | Session.Metadata.Status.Archived -> print_hints [ restore_hint ]
           | Session.Metadata.Status.Deleted -> ()));
       Ok Success))

let update ~command last id f =
  with_host @@ fun ~stdenv host ->
  status
    (let store = store stdenv host in
     let* document = resolve_target ~command ~stdenv host last id in
     let id = Session.id (Store.Document.session document) in
     let* session =
       session_document ~id (f (Store.Document.session document))
     in
     let* document = session_store ~id (Store.save store document session) in
     stdout_printf "%s\n"
       (id_string (Session.id (Store.Document.session document)));
     Ok Success)

let archive last id = update ~command:"session archive" last id Session.archive
let restore last id = update ~command:"session restore" last id Session.restore

let rename last id title =
  if String.is_empty title then status (usage "session title must not be empty")
  else
    update ~command:"session rename" last id (fun session ->
        Ok (Session.set_title (Some title) session))

let delete yes last id =
  if not yes then status (usage "session delete requires --yes")
  else update ~command:"session delete" last id Session.delete

let fork last parent child title =
  with_host @@ fun ~stdenv host ->
  status
    (let store = store stdenv host in
     let* () = validate_title title in
     let* document =
       resolve_target ~command:"session fork" ~stdenv host last parent
     in
     let* cwd = assembly (host_cwd host) in
     let* child =
       execution
         (Host_session.fork ~store ~clock:(Eio.Stdenv.clock stdenv) ~id:child
            ?title ~cwd document)
     in
     stdout_printf "%s\n"
       (id_string (Session.id (Store.Document.session child)));
     Ok Success)

let rewind_edge ~before ~after =
  match (before, after) with
  | _, false -> Ok `Before
  | false, true -> Ok `After
  | true, true -> usage "use at most one of --before or --after"

type export_format = Json | Text | Markdown

let pp_event_line event = Format.asprintf "%a" Session.Event.pp event

let print_export_text session =
  let metadata = Session.metadata session in
  stdout_printf "id: %s\n" (id_string (Session.id session));
  stdout_printf "title: %s\n"
    (Option.value (Session.Metadata.title metadata) ~default:"-");
  stdout_printf "status: %s\n"
    (status_string (Session.Metadata.status metadata));
  stdout_printf "events: %d\n" (List.length (Session.events session));
  List.iteri
    (fun index event ->
      stdout_printf "%d. %s\n" (index + 1) (pp_event_line event))
    (Session.events session)

let print_export_markdown session =
  let metadata = Session.metadata session in
  let events = Session.events session in
  stdout_printf "# Session %s\n" (id_string (Session.id session));
  stdout_printf "- Title: %s\n"
    (Option.value (Session.Metadata.title metadata) ~default:"-");
  stdout_printf "- Status: %s\n"
    (status_string (Session.Metadata.status metadata));
  stdout_printf "- Events: %d\n" (List.length events);
  if not (List.is_empty events) then begin
    stdout_printf "\n## Events\n\n";
    List.iteri
      (fun index event ->
        stdout_printf "%d. `%s`\n" (index + 1) (pp_event_line event))
      events
  end

let export format last id =
  with_host @@ fun ~stdenv host ->
  status
    (let* document =
       resolve_target ~command:"session export" ~stdenv host last id
     in
     let session = Store.Document.session document in
     match format with
     | Json ->
         let* text =
           Jsont_bytesrw.encode_string Session.jsont session
           |> Result.map_error (fun message -> `Runtime message)
         in
         stdout_printf "%s\n" text;
         Ok Success
     | Text ->
         print_export_text session;
         Ok Success
     | Markdown ->
         print_export_markdown session;
         Ok Success)

let print_compaction_human session compaction =
  let range =
    match Session.Compaction.range compaction with
    | None -> ""
    | Some range ->
        " summarized="
        ^ string_of_int (Session.Compaction.Range.summarized_messages range)
        ^ " retained="
        ^ string_of_int (Session.Compaction.Range.retained_tail_messages range)
  in
  stdout_printf "compacted %s%s\n" (id_string (Session.id session)) range

(* Manual compaction requires an active-lifecycle idle session, rejected
   before any model or credential work. Archived and deleted sessions report
   their lifecycle (with the restore hint), waiting sessions point at their
   waiting, and any other active turn — including stale mid-flight turns —
   must finish or be interrupted first. Automatic compaction during execution
   is unaffected by this rule. *)
let require_idle_for_compaction session =
  match Session.Metadata.status (Session.metadata session) with
  | Session.Metadata.Status.Archived ->
      Error (`Execution (Spice_protocol.Error.Archived (Session.id session)))
  | Session.Metadata.Status.Deleted ->
      Error (`Execution (Spice_protocol.Error.Deleted (Session.id session)))
  | Session.Metadata.Status.Active -> (
      let reject message hint =
        Error
          (`Runtime
             (Spice_diagnostic.to_string
                (Spice_diagnostic.make ~hints:[ hint ] message)))
      in
      match Cli_block.phase session with
      | Cli_block.Idle -> Ok ()
      | Cli_block.Waiting _ ->
          reject
            "session is waiting; resolve the waiting before manual compaction"
            ("see the waiting and its continuation commands: spice session \
              show "
            ^ shell_arg (id_string (Session.id session)))
      | Cli_block.Active ->
          reject
            "session has an active turn; manual compaction requires an idle \
             session"
            ("resume it: "
            ^ Cli_block.resume_invocation ~session:(Session.id session)))

let compact json model cwd last id =
  with_host ?cwd @@ fun ~stdenv host ->
  Eio.Switch.run @@ fun sw ->
  status
    (let store = store stdenv host in
     let* document =
       resolve_target ~command:"session compact" ~stdenv host last id
     in
     let* () = require_idle_for_compaction (Store.Document.session document) in
     let* client, policy = Cli_run.summary_compaction ~sw ~stdenv host model in
     let* { Spice_host.Compactor.document; compaction } =
       execution (Host_session.compact ~store ~client ~policy document)
     in
     let session = Store.Document.session document in
     if json then
       stdout_printf "%s\n"
         (json_string
            (Cli_run.compaction_installed_json session
               (Store.Document.revision document)
               compaction))
     else print_compaction_human session compaction;
     Ok Success)

let item_matches query item =
  let query = String.lowercase_ascii query in
  let includes text =
    String.includes ~affix:query (String.lowercase_ascii text)
  in
  includes (id_string (Summary.id item))
  || includes (Option.value (Summary.title item) ~default:"")
  || includes (Option.value (Summary.preview item) ~default:"")

let search json all include_archived include_deleted limit query =
  with_host @@ fun ~stdenv host ->
  status
    (let* limit = normalized_limit limit in
     let store = store stdenv host in
     let* cwd = assembly (host_cwd host) in
     let matches document =
       item_matches query (Host_session.of_document document)
     in
     let filter document = (all || in_cwd cwd document) && matches document in
     let* documents, corrupt =
       session_store
         (Store.list store ~include_archived ~include_deleted ~filter
            ?limit:(overfetch_limit limit) ())
     in
     warn_corrupt corrupt;
     let items, truncated =
       documents |> List.map Host_session.of_document |> split_truncated limit
     in
     if json then
       print_versioned_json "session_search"
         ([
            ("query", Jsont.Json.string query);
            ("sessions", json_list (List.map list_item_json items));
          ]
         @ corrupt_field corrupt)
     else (
       print_items ~now:(now_for_render stdenv)
         ~show_lifecycle:(include_archived || include_deleted)
         ~show_cwd:all items;
       if truncated then
         stderr_printf
           "spice: session search truncated; use --limit 0 to show all\n");
     Ok Success)

let json = Cli_arg.json_flag ()

let title =
  Arg.(
    value
    & opt (some string) None
    & info [ "title" ] ~docv:"TITLE" ~doc:"Session title.")

let session_id_pos doc = Cli_arg.session_pos ~doc ()
let last_flag = Cli_arg.last_flag ()

let child_id =
  Arg.(
    required
    & opt (some Cli_arg.session_id) None
    & info [ "id" ] ~docv:"ID" ~doc:"New child session id.")

let optional_id =
  Arg.(
    value
    & opt (some Cli_arg.session_id) None
    & info [ "id" ] ~docv:"ID" ~doc:"Session id. Defaults to a generated id.")

let to_turn =
  Arg.(
    required
    & opt (some string) None
    & info [ "to-turn" ] ~docv:"TURN"
        ~doc:"Turn boundary to rewind to, named by its turn id.")

let before_flag =
  Arg.(
    value & flag
    & info [ "before" ]
        ~doc:
          "Anchor just before the turn started, dropping it and every later \
           turn. This is the default.")

let after_flag =
  Arg.(
    value & flag
    & info [ "after" ]
        ~doc:
          "Anchor just after the turn finished, keeping it and dropping every \
           later turn.")

let revert_fs_flag =
  Arg.(
    value & flag
    & info [ "revert-fs" ]
        ~doc:
          "Also revert the workspace to match the rewind point, undoing the \
           dropped turns' Spice-authored file changes all-or-nothing. A stale \
           file or missing evidence refuses the whole revert; the transcript \
           rewind still lands.")

let include_archived =
  Arg.(value & flag & info [ "archived" ] ~doc:"Include archived sessions.")

let include_deleted =
  Arg.(value & flag & info [ "deleted" ] ~doc:"Include deleted sessions.")

let all =
  Arg.(
    value & flag & info [ "all" ] ~doc:"Include sessions from all cwd scopes.")

let limit =
  Arg.(
    value
    & opt (some int) None
    & info [ "n"; "limit" ] ~docv:"N" ~doc:"Limit the number of sessions read.")

let query =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"QUERY" ~doc:"Search text.")

let new_title =
  Arg.(
    required
    & pos 1 (some string) None
    & info [] ~docv:"TITLE" ~doc:"New session title.")

let model = Cli_arg.model_opt ()
let cwd = Cli_arg.cwd ()

let yes =
  Arg.(value & flag & info [ "yes" ] ~doc:"Confirm the destructive operation.")

let export_format =
  Arg.(
    value
    & opt (enum [ ("json", Json); ("text", Text); ("markdown", Markdown) ]) Json
    & info [ "format" ] ~docv:"FORMAT"
        ~doc:"Export format: json, text, or markdown.")

(* Workspace mutation evidence: diff and revert.

   Both commands are pure projections over the mutation ledger plus the
   checkpoint backend; neither loads a model. Diff never mutates anything;
   revert previews by default and lowers to [Spice_edit] on --apply so it
   inherits locking and stale rejection. *)

module Mutations = Spice_host.Mutations
module Mutation = Spice_mutation

let mutation_log stdenv store =
  Mutations.Log.make ~fs:(Eio.Stdenv.fs stdenv)
    ~root:(Store.root store |> Spice_path.Abs.to_string)

let run_git stdenv argv =
  match
    Eio.Process.parse_out
      ~stderr:(Eio.Flow.buffer_sink (Buffer.create 256))
      (Eio.Stdenv.process_mgr stdenv)
      Eio.Buf_read.take_all argv
  with
  | output -> Ok output
  | exception exn -> Error (Printexc.to_string exn)

let session_workspace document =
  let cwd =
    Session.Metadata.cwd (Session.metadata (Store.Document.session document))
  in
  let root = Spice_workspace.Root.make cwd in
  (Spice_path.Abs.to_string cwd, root, Spice_workspace.single root)

let session_backend stdenv store ~workspace_root =
  Mutations.Backend.git_tree ~fs:(Eio.Stdenv.fs stdenv) ~run:(run_git stdenv)
    ~data_root:(Store.root store |> Spice_path.Abs.to_string)
    ~workspace_root ()

let mutation_error result = Result.map_error (fun m -> `Runtime m) result

(* Current workspace reads for revert planning. *)
let read_target ~stdenv ~root rel =
  let abs =
    Spice_path.Abs.to_string
      (Spice_workspace.Path.abs (Spice_workspace.Path.make ~root rel))
  in
  match Eio.Path.load (Eio.Path.( / ) (Eio.Stdenv.fs stdenv) abs) with
  | contents ->
      if String.is_valid_utf_8 contents then Spice_edit.Observed.Text contents
      else Spice_edit.Observed.Other
  | exception _ -> Spice_edit.Observed.Missing

(* Scope selection shared by diff and revert. [latest] resolves to the most
   recent turn that recorded change rows. *)
let latest_turn changes =
  match List.rev changes with
  | [] -> None
  | change :: _ -> Some (Mutation.Change.turn change)

let parse_rel text =
  match Spice_path.Rel.of_string text with
  | Ok rel -> Ok rel
  | Error error -> usage (Spice_path.Error.message error)

let diff_scope ~latest ~turn ~path changes =
  match (latest, turn, path) with
  | false, None, None -> Ok (Some Mutation.Scope.Session)
  | true, None, None ->
      Ok
        (Option.map
           (fun turn -> Mutation.Scope.Turn turn)
           (latest_turn changes))
  | false, Some turn, None ->
      Ok (Some (Mutation.Scope.Turn (Session.Turn.Id.of_string turn)))
  | false, None, Some path ->
      let* rel = parse_rel path in
      Ok (Some (Mutation.Scope.Path rel))
  | _ -> usage "use at most one of --latest, --turn, or --path"

let revert_scope ~latest ~change ~path changes =
  match (latest, change, path) with
  | true, None, None ->
      Ok
        (Option.map
           (fun turn -> Mutation.Scope.Turn turn)
           (latest_turn changes))
  | false, Some change, None ->
      Ok (Some (Mutation.Scope.Change (Mutation.Change.Id.of_string change)))
  | false, None, Some path ->
      let* rel = parse_rel path in
      Ok (Some (Mutation.Scope.Path rel))
  | _ -> usage "use exactly one of --latest, --change, or --path"

let op_letter (entry : Mutation.Change.Net.entry) =
  match (entry.Mutation.Change.Net.before, entry.Mutation.Change.Net.after) with
  | Mutation.Image.Missing, _ -> "A"
  | _, Mutation.Image.Missing -> "D"
  | _, _ -> "M"

let blob_contents ~log image =
  match (image : Mutation.Image.t) with
  | Mutation.Image.Missing -> Ok None
  | Mutation.Image.Unsupported _ -> Ok None
  | Mutation.Image.Text { identity; _ } -> (
      match Mutations.Log.blob log identity with
      | Ok (Some contents) -> Ok (Some contents)
      | Ok None -> Error "evidence blob missing"
      | Error message -> Error message)

let net_file_change ~log (entry : Mutation.Change.Net.entry) =
  let* before =
    mutation_error (blob_contents ~log entry.Mutation.Change.Net.before)
  in
  let* after =
    mutation_error (blob_contents ~log entry.Mutation.Change.Net.after)
  in
  let label =
    Spice_diff.Label.escaped
      (Spice_path.Rel.to_string entry.Mutation.Change.Net.path)
  in
  Ok (Spice_diff.File_change.of_states ~label ~before ~after)

(* Shell attribution: bounded by the run window between the Before_mutation
   and Run_end checkpoints; only derivable for turn scopes. *)
let unattributed ~stdenv ~store ~workspace_root ~records ~session_id ~turn net =
  let checkpoints = Mutation.checkpoints records in
  let available reason =
    let id = Mutation.Checkpoint.derive_id ~session:session_id ~turn ~reason in
    List.find_map
      (fun checkpoint ->
        if
          not
            (Mutation.Checkpoint.Id.equal
               (Mutation.Checkpoint.id checkpoint)
               id)
        then None
        else
          match Mutation.Checkpoint.status checkpoint with
          | Mutation.Checkpoint.Available { reference; _ } -> Some reference
          | Mutation.Checkpoint.Degraded _ -> None)
      checkpoints
  in
  match
    ( available Mutation.Checkpoint.Before_mutation,
      available Mutation.Checkpoint.Run_end )
  with
  | Some from_, Some to_ -> (
      match session_backend stdenv store ~workspace_root with
      | None -> `Degraded "checkpoint backend unavailable"
      | Some backend -> (
          match backend.Mutations.Backend.paths ~from_ ~to_ with
          | Error message -> `Degraded message
          | Ok paths ->
              let covered =
                List.map
                  (fun (entry : Mutation.Change.Net.entry) ->
                    entry.Mutation.Change.Net.path)
                  net
              in
              `Paths
                (List.filter
                   (fun (path, _) ->
                     not (List.exists (Spice_path.Rel.equal path) covered))
                   paths)))
  | _ -> `Degraded "shell ran; unattributed changes unknown"

let shell_ran_in_turn session turn =
  List.exists
    (fun (started, _) ->
      Session.Turn.Id.equal (Session.Tool_claim.Started.turn started) turn
      && String.equal
           (Tool_call.name (Session.Tool_claim.Started.call started))
           "shell")
    (Session.State.tool_claims (Session.state session))

let plural n = if n = 1 then "file" else "files"

let net_json (entry : Mutation.Change.Net.entry) =
  Cli_common.json_obj
    [
      ( "path",
        Jsont.Json.string
          (Spice_path.Rel.to_string entry.Mutation.Change.Net.path) );
      ("operation", Jsont.Json.string (op_letter entry));
      ("contiguous", Jsont.Json.bool entry.Mutation.Change.Net.contiguous);
      ( "sources",
        Jsont.Json.list
          (List.map
             (fun id -> Jsont.Json.string (Mutation.Change.Id.to_string id))
             entry.Mutation.Change.Net.sources) );
    ]

let diff json cwd latest turn path last id =
  with_host ?cwd @@ fun ~stdenv host ->
  status
    (let store = store stdenv host in
     let* document =
       resolve_target ~command:"session diff" ~stdenv host last id
     in
     let id = Session.id (Store.Document.session document) in
     let log = mutation_log stdenv store in
     let* records = mutation_error (Mutations.Log.read log ~session:id) in
     let changes = Mutation.changes records in
     let* scope = diff_scope ~latest ~turn ~path changes in
     let selected =
       match scope with
       | None -> []
       | Some scope -> Mutation.Scope.select scope changes
     in
     let net = Mutation.Change.net selected in
     let* file_changes =
       List.fold_left
         (fun acc entry ->
           let* acc = acc in
           let* change = net_file_change ~log entry in
           Ok (match change with None -> acc | Some change -> change :: acc))
         (Ok []) net
       |> Result.map List.rev
     in
     let rendered = Spice_diff.render file_changes in
     let stats = Spice_diff.stats rendered in
     let workspace_root, _, _ = session_workspace document in
     let shell_note =
       match scope with
       | Some (Mutation.Scope.Turn turn)
         when shell_ran_in_turn (Store.Document.session document) turn -> (
           match
             unattributed ~stdenv ~store ~workspace_root ~records ~session_id:id
               ~turn net
           with
           | `Paths [] -> `None
           | `Paths paths -> `Paths paths
           | `Degraded message -> `Degraded message)
       | _ -> `None
     in
     if json then (
       let unattributed_fields =
         match shell_note with
         | `None -> []
         | `Paths paths ->
             [
               ( "unattributed",
                 Jsont.Json.list
                   (List.map
                      (fun (path, _) ->
                        Jsont.Json.string (Spice_path.Rel.to_string path))
                      paths) );
             ]
         | `Degraded message -> [ ("degraded", Jsont.Json.string message) ]
       in
       stdout_printf "%s\n"
         (json_string
            (json_envelope ~type_:"session.diff"
               ([
                  ("session_id", Jsont.Json.string (id_string id));
                  ("files", Jsont.Json.int stats.Spice_diff.files);
                  ("additions", Jsont.Json.int stats.Spice_diff.additions);
                  ("deletions", Jsont.Json.int stats.Spice_diff.deletions);
                  ("changes", Jsont.Json.list (List.map net_json net));
                  ("diff", Jsont.Json.string (Spice_diff.to_string rendered));
                ]
               @ unattributed_fields)));
       Ok Success)
     else (
       stdout_printf "changed %d %s (+%d -%d)\n" stats.Spice_diff.files
         (plural stats.Spice_diff.files)
         stats.Spice_diff.additions stats.Spice_diff.deletions;
       List.iter
         (fun (entry : Mutation.Change.Net.entry) ->
           stdout_printf "%s %s%s\n" (op_letter entry)
             (Spice_path.Rel.to_string entry.Mutation.Change.Net.path)
             (if entry.Mutation.Change.Net.contiguous then ""
              else " (discontinuous)"))
         net;
       if not (Spice_diff.is_empty rendered) then
         stdout_printf "%s" (Spice_diff.to_string rendered);
       (match shell_note with
       | `None -> ()
       | `Paths paths ->
           List.iter
             (fun (path, _) ->
               stdout_printf
                 "changed during run (unattributed; not revertable): %s\n"
                 (Spice_path.Rel.to_string path))
             paths
       | `Degraded message ->
           stdout_printf "shell ran; unattributed changes unknown (%s)\n"
             message);
       Ok Success))

(* Revert: lower the plan to Spice_edit so apply inherits locking,
   revalidation, and stale rejection. *)

let revert_io ~stdenv ~workspace () =
  let fs = Eio.Stdenv.fs stdenv in
  Spice_workspace_fs.Edit.io ~fs ~workspace ~max_bytes:max_int
    ~allow_remove:true ()
  |> fst

let revert_rows ~log ~session_id ~turn ~revert (result : Spice_edit.Result.t) =
  let index = ref (-1) in
  List.fold_left
    (fun acc (entry : Spice_edit.Result.Entry.t) ->
      let* rows = acc in
      incr index;
      let path =
        Spice_workspace.Path.rel (Spice_edit.Result.Entry.target_path entry)
      in
      let op =
        match Spice_edit.Result.Entry.kind entry with
        | `Create -> Mutation.Change.Create
        | `Modify -> Mutation.Change.Modify
        | `Delete -> Mutation.Change.Delete
      in
      let image target =
        let* () =
          match (target : Spice_edit.Observed.t) with
          | Spice_edit.Observed.Text contents ->
              mutation_error
                (Result.map ignore (Mutations.Log.put_blob log contents))
          | Spice_edit.Observed.Missing | Spice_edit.Observed.Other -> Ok ()
        in
        Ok (Mutation.Image.of_target target)
      in
      let* before = image (Spice_edit.Result.Entry.before entry) in
      let* after = image (Spice_edit.Result.Entry.after entry) in
      let id =
        Mutation.Change.Id.of_string
          (Printf.sprintf "change:%s:%s:%d"
             (Mutation.Revert_id.to_string revert)
             (Spice_path.Rel.to_string path)
             !index)
      in
      Ok
        (Mutation.Change.make ~id ~session:session_id ~turn
           ~source:(Mutation.Change.Revert revert) ~path ~op ~before ~after
           ~additions:0 ~deletions:0 ~revertability:Mutation.Change.Revertable
           ()
        :: rows))
    (Ok [])
    (Spice_edit.Result.entries result)
  |> Result.map List.rev

(* Capture a Before_revert safety checkpoint into [session]'s ledger when a
   backend is available, returning the id to name on the revert fact. *)
let capture_before_revert ~stdenv ~store ~log ~workspace_root ~session ~turn =
  match session_backend stdenv store ~workspace_root with
  | None -> None
  | Some backend -> (
      match backend.Mutations.Backend.capture () with
      | Error _ -> None
      | Ok Mutations.Backend.{ reference; excluded } -> (
          let fact =
            Mutation.Checkpoint.make
              ~id:
                (Mutation.Checkpoint.derive_id ~session ~turn
                   ~reason:Mutation.Checkpoint.Before_revert)
              ~session ~turn ~root:workspace_root
              ~reason:Mutation.Checkpoint.Before_revert
              ~status:
                (Mutation.Checkpoint.Available
                   {
                     backend = backend.Mutations.Backend.name;
                     reference;
                     excluded;
                   })
          in
          match
            Mutations.Log.append log ~session
              [ Mutation.Record.Checkpoint fact ]
          with
          | Ok () -> Some (Mutation.Checkpoint.id fact)
          | Error _ -> None))

(* Apply a lowered revert [edits] against [workspace] and record its facts — the
   Revert fact plus inverse Change rows — into [target]'s ledger, keyed by
   [turn]. [prior_reverts] disambiguates the derived revert id. Before-images and
   blob writes go through [log] at the shared data root, so a child ledger
   resolves the parent's before-image blobs. Returns the revert id and the
   number of restored paths. *)
let apply_and_record_revert ~stdenv ~store ~log ~workspace ~workspace_root
    ~target ~turn ~scope ~prior_reverts ~ready edits =
  let ordinal =
    List.length
      (List.filter
         (fun revert ->
           Mutation.Scope.equal (Mutation.Revert.scope revert) scope)
         prior_reverts)
  in
  let revert_id = Mutation.Revert.derive_id ~session:target ~scope ~ordinal in
  let pre_revert =
    capture_before_revert ~stdenv ~store ~log ~workspace_root ~session:target
      ~turn
  in
  match
    Spice_edit.apply ~io:(revert_io ~stdenv ~workspace ()) ~workspace edits
  with
  | Error error ->
      Error
        (`Runtime ("revert failed: " ^ Spice_edit.Apply_error.message error))
  | Ok result ->
      let* rows =
        revert_rows ~log ~session_id:target ~turn ~revert:revert_id result
      in
      let applied =
        List.map
          (fun (r : Mutation.Revert.ready) ->
            {
              Mutation.Revert.applied_path = r.Mutation.Revert.ready_path;
              applied_sources = r.Mutation.Revert.sources;
            })
          ready
      in
      let fact =
        Mutation.Revert.make ?pre_revert ~id:revert_id ~session:target ~scope
          ~applied ()
      in
      let* () =
        mutation_error
          (Mutations.Log.append log ~session:target
             (Mutation.Record.Revert fact
             :: List.map (fun row -> Mutation.Record.Change row) rows))
      in
      Ok (revert_id, List.length (Spice_edit.Result.entries result))

let describe_revert_problem = function
  | Mutation.Revert.Stale stale ->
      Printf.sprintf "stale %s: expected %s"
        (Spice_path.Rel.to_string stale.Mutation.Revert.stale_path)
        (Format.asprintf "%a" Mutation.Image.pp stale.Mutation.Revert.expected)
  | Mutation.Revert.Refused refusal ->
      Printf.sprintf "refused %s: %s"
        (Spice_path.Rel.to_string refusal.Mutation.Revert.refusal_path)
        refusal.Mutation.Revert.reason

let revert json cwd apply latest change path last id =
  with_host ?cwd @@ fun ~stdenv host ->
  status
    (let store = store stdenv host in
     let* document =
       resolve_target ~command:"session revert" ~stdenv host last id
     in
     let id = Session.id (Store.Document.session document) in
     let log = mutation_log stdenv store in
     let* records = mutation_error (Mutations.Log.read log ~session:id) in
     let changes = Mutation.changes records in
     let* scope = revert_scope ~latest ~change ~path changes in
     match scope with
     | None ->
         stdout_printf "nothing to revert\n";
         Ok Success
     | Some scope -> (
         let workspace_root, root, workspace = session_workspace document in
         let read = read_target ~stdenv ~root in
         let plan = Mutation.Revert.plan ~read ~scope changes in
         if not apply then (
           stdout_printf "would revert %d %s:\n"
             (List.length plan.Mutation.Revert.ready)
             (plural (List.length plan.Mutation.Revert.ready));
           List.iter
             (fun (ready : Mutation.Revert.ready) ->
               stdout_printf "%s %s\n"
                 (match
                    ( ready.Mutation.Revert.restore,
                      ready.Mutation.Revert.current )
                  with
                 | Mutation.Image.Missing, _ -> "D"
                 | _, None -> "A"
                 | _, Some _ -> "M")
                 (Spice_path.Rel.to_string ready.Mutation.Revert.ready_path))
             plan.Mutation.Revert.ready;
           List.iter
             (fun problem ->
               stdout_printf "%s\n" (describe_revert_problem problem))
             plan.Mutation.Revert.problems;
           if
             plan.Mutation.Revert.problems = []
             && plan.Mutation.Revert.ready <> []
           then
             (* Flags before the positional id (routed through
                [Cli_block.positional_arg]) so the hint survives copy-paste for a
                dash-prefixed id, which cmdliner would read as an option. *)
             stdout_printf "apply: spice session revert %s--apply %s\n"
               (match scope with
               | Mutation.Scope.Turn _ | Mutation.Scope.Turns _ -> "--latest "
               | Mutation.Scope.Change change ->
                   "--change " ^ Mutation.Change.Id.to_string change ^ " "
               | Mutation.Scope.Path path ->
                   "--path " ^ Spice_path.Rel.to_string path ^ " "
               | Mutation.Scope.Session -> "")
               (Cli_block.positional_arg (id_string id));
           Ok Success)
         else
           let resolve rel = Ok (Spice_workspace.Path.make ~root rel) in
           let blob identity =
             match Mutations.Log.blob log identity with
             | Ok contents -> contents
             | Error _ -> None
           in
           match Mutation.Revert.lower plan ~resolve ~blob with
           | Error problems ->
               List.iter
                 (fun problem ->
                   stderr_printf "%s\n" (describe_revert_problem problem))
                 problems;
               Error (`Runtime "revert refused; no files were changed")
           | Ok edits ->
               let turn =
                 match latest_turn (Mutation.Scope.select scope changes) with
                 | Some turn -> turn
                 | None -> Session.Turn.Id.of_string "turn-unknown"
               in
               let* revert_id, reverted =
                 apply_and_record_revert ~stdenv ~store ~log ~workspace
                   ~workspace_root ~target:id ~turn ~scope
                   ~prior_reverts:(Mutation.reverts records)
                   ~ready:plan.Mutation.Revert.ready edits
               in
               if json then
                 stdout_printf "%s\n"
                   (json_string
                      (json_envelope ~type_:"session.revert"
                         [
                           ("session_id", Jsont.Json.string (id_string id));
                           ( "revert_id",
                             Jsont.Json.string
                               (Mutation.Revert_id.to_string revert_id) );
                           ("reverted", Jsont.Json.int reverted);
                         ]))
               else stdout_printf "reverted %d %s\n" reverted (plural reverted);
               Ok Success))

(* The filesystem half of a rewind, over the dropped turns' change rows. The
   transcript rewind has already landed durably, so this reverts the workspace
   into the [child]'s ledger all-or-nothing: a stale file or a missing before-
   image refuses the whole revert while the child stays. Reads the parent's
   change rows and resolves the parent's before-image blobs through one [log] at
   the shared data root; the child ledger it writes into is keyed by [child]. *)
let rewind_revert ~stdenv ~store ~document ~parent ~child ~dropped =
  let log = mutation_log stdenv store in
  let* records = mutation_error (Mutations.Log.read log ~session:parent) in
  let changes = Mutation.changes records in
  let scope = Mutation.Scope.Turns dropped in
  let workspace_root, root, workspace = session_workspace document in
  let read = read_target ~stdenv ~root in
  let plan = Mutation.Revert.plan ~read ~scope changes in
  if plan.Mutation.Revert.ready = [] && plan.Mutation.Revert.problems = [] then
    Ok (`Applied 0)
  else
    let resolve rel = Ok (Spice_workspace.Path.make ~root rel) in
    let blob identity =
      match Mutations.Log.blob log identity with
      | Ok contents -> contents
      | Error _ -> None
    in
    match Mutation.Revert.lower plan ~resolve ~blob with
    | Error problems ->
        Ok (`Refused (List.map describe_revert_problem problems))
    | Ok edits ->
        let turn =
          match latest_turn (Mutation.Scope.select scope changes) with
          | Some turn -> turn
          | None -> Session.Turn.Id.of_string "turn-unknown"
        in
        let* _revert_id, reverted =
          apply_and_record_revert ~stdenv ~store ~log ~workspace ~workspace_root
            ~target:child ~turn ~scope ~prior_reverts:[]
            ~ready:plan.Mutation.Revert.ready edits
        in
        Ok (`Applied reverted)

let rewind json last session to_turn before after revert_fs child =
  with_host @@ fun ~stdenv host ->
  status
    (let store = store stdenv host in
     let* edge = rewind_edge ~before ~after in
     let* turn =
       if String.is_empty to_turn then
         usage "session rewind --to-turn must not be empty"
       else Ok (Session.Turn.Id.of_string to_turn)
     in
     let* document =
       resolve_target ~command:"session rewind" ~stdenv host last session
     in
     let parent_session = Store.Document.session document in
     let parent = Session.id parent_session in
     let* cwd = assembly (host_cwd host) in
     let anchor =
       match edge with
       | `Before -> Session.Anchor.before_turn turn
       | `After -> Session.Anchor.after_turn turn
     in
     (* Pure preview: which turns the anchor drops. Sharing this derivation with
        the engine keeps the "kept/dropped" summary honest and surfaces an
        unknown or unfinished turn as a recoverable input error before the
        engine flattens it. *)
     let* dropped =
       session_document ~id:parent (Session.dropped_turns anchor parent_session)
     in
     let kept =
       List.length (Session.State.turns (Session.state parent_session))
       - List.length dropped
     in
     let* child_document =
       execution
         (Host_session.rewind ~store ~id:child ~cwd ~created_at:(now stdenv)
            anchor document)
     in
     let child_id = Session.id (Store.Document.session child_document) in
     (* The transcript rewind above is durable now; the workspace revert below
        is a paired best effort that refuses cleanly, leaving the child. *)
     let* revert_outcome =
       if not revert_fs then Ok `Not_requested
       else
         rewind_revert ~stdenv ~store ~document ~parent ~child:child_id ~dropped
     in
     (* The ledger only owns Spice-authored change rows, so a revert can never
        touch files a shell command or a hand edit changed. Say so plainly (a
        standing caveat, not a per-file detection) so the user knows the
        workspace is only Spice-attributably reverted. *)
     let unaffected_caveat =
       "warning: rewind does not affect files changed by shell commands or \
        manual edits"
     in
     if json then
       print_versioned_json "session"
         ([
            ("session", list_item_json (Host_session.of_document child_document));
            ("kept", Jsont.Json.int kept);
            ( "dropped",
              json_list
                (List.map
                   (fun turn -> Jsont.Json.string (turn_id_string turn))
                   dropped) );
          ]
         @
         match revert_outcome with
         | `Not_requested -> []
         | `Applied reverted ->
             [
               ( "reverted",
                 Cli_common.json_obj
                   [
                     ("files", Jsont.Json.int reverted);
                     ("unaffected", Jsont.Json.string unaffected_caveat);
                   ] );
             ]
         | `Refused problems ->
             [
               ( "reverted",
                 Cli_common.json_obj
                   [
                     ( "refused",
                       Jsont.Json.list
                         (List.map (fun m -> Jsont.Json.string m) problems) );
                   ] );
             ])
     else begin
       stdout_printf "%s\n" (id_string child_id);
       stdout_printf "rewound %s: kept %d dropped %d\n" (id_string parent) kept
         (List.length dropped);
       match revert_outcome with
       | `Not_requested -> ()
       | `Applied reverted ->
           stdout_printf "reverted %d %s in workspace\n" reverted
             (plural reverted);
           stdout_printf "%s\n" unaffected_caveat
       | `Refused problems ->
           List.iter (fun message -> stdout_printf "%s\n" message) problems;
           stdout_printf
             "workspace not reverted; transcript rewind is durable\n"
     end;
     Ok Success)

let latest_flag =
  Arg.(value & flag & info [ "latest" ] ~doc:"Select the latest run (turn).")

let turn_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "turn" ] ~docv:"TURN" ~doc:"Select one turn id.")

let path_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "path" ] ~docv:"PATH"
        ~doc:"Select changes that touched one workspace-relative path.")

let change_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "change" ] ~docv:"ID" ~doc:"Select one change row.")

let apply_flag =
  Arg.(
    value & flag
    & info [ "apply" ]
        ~doc:"Apply the revert. Without this flag the command previews.")

let diff_command =
  Cmd.v
    (Cmd.info "diff" ~doc:"Show Spice-authored workspace changes."
       ~man:
         [
           `S Cmdliner.Manpage.s_description;
           `P
             "Renders the workspace changes recorded in the session's mutation \
              ledger. $(b,--latest) scopes to the most recent turn, \
              $(b,--turn) to one turn, and $(b,--path) to one file.";
           `S Cmdliner.Manpage.s_examples;
           `Pre "  spice session diff --last --latest";
           `Pre "  spice session diff ses_123 --path lib/foo.ml";
         ]
       ~exits)
    (exit_term
       Term.(
         const diff $ json $ cwd $ latest_flag $ turn_opt $ path_opt $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let revert_command =
  Cmd.v
    (Cmd.info "revert" ~doc:"Revert Spice-authored workspace changes."
       ~man:
         [
           `S Cmdliner.Manpage.s_description;
           `P
             "Previews by default; $(b,--apply) performs the revert through \
              the same stale-safe checks as editing, so a file changed since \
              the recorded mutation is refused rather than clobbered.";
           `S Cmdliner.Manpage.s_examples;
           `Pre "  spice session revert --last --latest";
           `Pre "  spice session revert ses_123 --latest --apply";
         ]
       ~exits)
    (exit_term
       Term.(
         const revert $ json $ cwd $ apply_flag $ latest_flag $ change_opt
         $ path_opt $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let create_command =
  Cmd.v
    (Cmd.info "create" ~doc:"Create an empty saved session." ~exits)
    (exit_term Term.(const create $ json $ optional_id $ title))

let list_command =
  Cmd.v
    (Cmd.info "list" ~doc:"List saved sessions." ~exits)
    (exit_term
       Term.(
         const list $ json $ all $ include_archived $ include_deleted $ limit))

let show_command =
  Cmd.v
    (Cmd.info "show" ~doc:"Show saved session metadata." ~exits)
    (exit_term
       Term.(
         const show $ json $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let fork_command =
  Cmd.v
    (Cmd.info "fork" ~doc:"Fork a saved session document." ~exits)
    (exit_term
       Term.(
         const fork $ last_flag
         $ session_id_pos "Parent session id or unique prefix."
         $ child_id $ title))

let rewind_command =
  Cmd.v
    (Cmd.info "rewind"
       ~doc:"Rewind a saved session to a turn boundary, into a new child."
       ~man:
         [
           `S Cmdliner.Manpage.s_description;
           `P
             "Rewind is fork-at-a-turn-boundary: it mints a new child session \
              whose transcript is the parent's prefix up to the chosen turn, \
              leaving the parent untouched. $(b,--before) (the default) drops \
              the named turn and everything after it; $(b,--after) keeps the \
              named turn and drops the rest. Rewinding to a boundary before a \
              compaction revives the pre-compaction transcript. By default the \
              rewind is transcript-only; pass $(b,--revert-fs) to also revert \
              the workspace to the rewind point, undoing the dropped turns' \
              Spice-authored file changes all-or-nothing.";
           `S Cmdliner.Manpage.s_examples;
           `Pre "  spice session rewind ses_123 --to-turn turn-2 --id ses_124";
           `Pre
             "  spice session rewind --last --to-turn turn-2 --after --id \
              ses_124";
           `Pre
             "  spice session rewind ses_123 --to-turn turn-2 --revert-fs --id \
              ses_124";
         ]
       ~exits)
    (exit_term
       Term.(
         const rewind $ json $ last_flag
         $ session_id_pos "Parent session id or unique prefix."
         $ to_turn $ before_flag $ after_flag $ revert_fs_flag $ child_id))

let archive_command =
  Cmd.v
    (Cmd.info "archive" ~doc:"Archive a saved session." ~exits)
    (exit_term
       Term.(
         const archive $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let restore_command =
  Cmd.v
    (Cmd.info "restore" ~doc:"Restore an archived session." ~exits)
    (exit_term
       Term.(
         const restore $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let rename_command =
  Cmd.v
    (Cmd.info "rename" ~doc:"Rename a saved session." ~exits)
    (exit_term
       Term.(
         const rename $ last_flag
         $ session_id_pos "Session id or unique prefix."
         $ new_title))

let delete_command =
  Cmd.v
    (Cmd.info "delete"
       ~doc:"Delete a saved session (kept as a recoverable tombstone)." ~exits)
    (exit_term
       Term.(
         const delete $ yes $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let export_command =
  Cmd.v
    (Cmd.info "export" ~doc:"Export a saved session document." ~exits)
    (exit_term
       Term.(
         const export $ export_format $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let compact_command =
  Cmd.v
    (Cmd.info "compact" ~doc:"Compact a saved session." ~exits)
    (exit_term
       Term.(
         const compact $ json $ model $ cwd $ last_flag
         $ session_id_pos "Session id or unique prefix."))

let search_command =
  Cmd.v
    (Cmd.info "search" ~doc:"Search saved session metadata." ~exits)
    (exit_term
       Term.(
         const search $ json $ all $ include_archived $ include_deleted $ limit
         $ query))

let group =
  Cmd.group
    (Cmd.info "session" ~doc:"Manage saved sessions." ~docs:s_session_commands
       ~man:
         [
           `S Cmdliner.Manpage.s_description;
           `P
             "Saved sessions are the durable record of every run: metadata, \
              the full event transcript, and any pending decision. Commands \
              that take a $(i,SESSION) accept a unique id prefix, and \
              $(b,--last) targets the newest session in the current working \
              directory.";
         ]
       ~exits)
    [
      create_command;
      list_command;
      show_command;
      fork_command;
      rewind_command;
      archive_command;
      restore_command;
      rename_command;
      delete_command;
      export_command;
      compact_command;
      search_command;
      diff_command;
      revert_command;
    ]
