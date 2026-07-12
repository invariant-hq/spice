(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Session = Spice_session
module Event = Spice_protocol.Event
module Tool_call = Spice_llm.Tool.Call
module Tools = Spice_tools
module W = Spice_workspace

type t =
  | Started of { execution : Session.Tool_claim.Started.t }
  | Finished of {
      execution : Session.Tool_claim.Started.t;
      result : Spice_tool.Output.t Spice_tool.Result.t;
    }
  | Workspace_changed of {
      execution : Session.Tool_claim.Started.t;
      checkpoint : Spice_mutation.Checkpoint.t option;
      changes : Spice_mutation.Change.t list;
      total : Spice_mutation.Change.totals;
    }

let of_timeline = function
  | Event.Tool_started execution -> Some (Started { execution })
  | Event.Tool_finished { claim; result } ->
      Some (Finished { execution = claim; result })
  | Event.Workspace_changed { claim; checkpoint; changes; total } ->
      Some (Workspace_changed { execution = claim; checkpoint; changes; total })
  (* Interrupted prose is an assistant transcript fact, never tool lifecycle. *)
  | Event.Turn_started _ | Event.Assistant _ | Event.Assistant_interrupted _
  | Event.Host_call _
  | Event.Permission_requested _ | Event.Permission_resolved _
  | Event.Compaction _ | Event.Turn_finished _ | Event.Assistant_delta _
  | Event.Reasoning_delta _ | Event.Usage_updated _ | Event.Model_started _
  | Event.Model_artifact _ | Event.Tool_updated _ | Event.Workspace_degraded _
  | Event.Compaction_progress _ | Event.Notices_injected _ ->
      None

(* JSON helpers *)

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let execution_fields execution =
  let call = Session.Tool_claim.Started.call execution in
  [
    ( "turn_id",
      Jsont.Json.string
        (Session.Turn.Id.to_string (Session.Tool_claim.Started.turn execution))
    );
    ("tool_call_id", Jsont.Json.string (Tool_call.id call));
    ( "tool_claim_id",
      Jsont.Json.string
        (Session.Tool_claim.Id.to_string
           (Session.Tool_claim.Started.id execution)) );
    ("tool", Jsont.Json.string (Tool_call.name call));
  ]

let failure_kind = function
  | `Invalid_input -> "invalid_input"
  | `Permission_denied -> "permission_denied"
  | `Not_found -> "not_found"
  | `Stale -> "stale"
  | `Unavailable -> "unavailable"
  | `Timed_out -> "timed_out"
  | `Failed -> "failed"

let status_fields result =
  match Spice_tool.Result.status result with
  | Spice_tool.Result.Completed -> [ ("status", Jsont.Json.string "completed") ]
  | Spice_tool.Result.Failed { kind; message; metadata = _ } ->
      [
        ("status", Jsont.Json.string "failed");
        ( "error",
          json_obj
            [
              ("kind", Jsont.Json.string (failure_kind kind));
              ("message", Jsont.Json.string message);
            ] );
      ]
  | Spice_tool.Result.Interrupted { reason; cancelled } ->
      [
        ("status", Jsont.Json.string "interrupted");
        ( "interrupted",
          json_obj
            [
              ("reason", Jsont.Json.string reason);
              ("cancelled", Jsont.Json.bool cancelled);
            ] );
      ]

(* Changed-file rows from typed evidence. Rendering facts, not audit rows:
   the durable ledger derivation lives in the host layer. *)

let changed_file ?from ?before_identity ?after_identity ~operation path =
  json_obj
    (List.filter_map Fun.id
       [
         Some ("path", Jsont.Json.string (W.Path.display path));
         Some ("operation", Jsont.Json.string operation);
         Option.map
           (fun from -> ("from", Jsont.Json.string (W.Path.display from)))
           from;
         Option.map
           (fun identity ->
             ( "before_identity",
               Jsont.Json.string (Spice_digest.Identity.to_string identity) ))
           before_identity;
         Option.map
           (fun identity ->
             ( "after_identity",
               Jsont.Json.string (Spice_digest.Identity.to_string identity) ))
           after_identity;
         Some ("revertable", Jsont.Json.bool true);
       ])

let operation_of_op = function
  | Spice_tools.Receipt.Create -> ("create", None)
  | Spice_tools.Receipt.Modify -> ("modify", None)
  | Spice_tools.Receipt.Delete -> ("delete", None)
  | Spice_tools.Receipt.Move { from } -> ("move", Some from)

let changed_files_of_receipt (receipt : Spice_tools.Receipt.t) =
  List.map
    (fun (change : Spice_tools.Receipt.change) ->
      let operation, from = operation_of_op change.Spice_tools.Receipt.op in
      changed_file ?from ~operation
        ?before_identity:
          (Spice_edit.Observed.identity change.Spice_tools.Receipt.before)
        ?after_identity:
          (Spice_edit.Observed.identity change.Spice_tools.Receipt.after)
        change.Spice_tools.Receipt.path)
    (Spice_tools.Receipt.changes receipt)

let changed_files_of_evidence = function
  | Tools.Evidence.Mutation { receipt; _ } -> changed_files_of_receipt receipt
  | Tools.Evidence.Read_file _ | Tools.Evidence.Search_text _
  | Tools.Evidence.Glob _ | Tools.Evidence.Web_fetch _
  | Tools.Evidence.Web_search _ | Tools.Evidence.Ocaml_eval _
  | Tools.Evidence.Ocaml_dune_describe _
  | Tools.Evidence.Ocaml_dune_diagnostics _
  | Tools.Evidence.Ocaml_find_definitions _
  | Tools.Evidence.Ocaml_find_references _
  | Tools.Evidence.Ocaml_search_expressions _ | Tools.Evidence.Ocaml_docs _
  | Tools.Evidence.Ocaml_type_at _ | Tools.Evidence.Shell _ ->
      []

let stream_json stream =
  match (stream : Tools.Shell.Output.stream) with
  | Tools.Shell.Output.Complete _ ->
      json_obj [ ("kind", Jsont.Json.string "complete") ]
  | Tools.Shell.Output.Truncated { omitted_bytes; _ } ->
      json_obj
        [
          ("kind", Jsont.Json.string "truncated");
          ("omitted_bytes", Jsont.Json.int omitted_bytes);
        ]

let process_json output =
  let status_fields =
    match Tools.Shell.Output.status output with
    | Tools.Shell.Output.Exited code -> [ ("exit_status", Jsont.Json.int code) ]
    | Tools.Shell.Output.Signaled signal ->
        [ ("signal", Jsont.Json.int signal) ]
    | Tools.Shell.Output.Timed_out { timeout_ms } ->
        [ ("timed_out_ms", Jsont.Json.int timeout_ms) ]
    | Tools.Shell.Output.Cancelled -> [ ("cancelled", Jsont.Json.bool true) ]
    | Tools.Shell.Output.Failed_to_start message ->
        [ ("failed_to_start", Jsont.Json.string message) ]
  in
  json_obj
    (status_fields
    @ [
        ("duration_ms", Jsont.Json.int (Tools.Shell.Output.duration_ms output));
        ("stdout", stream_json (Tools.Shell.Output.stdout output));
        ("stderr", stream_json (Tools.Shell.Output.stderr output));
        ( "sandbox",
          Spice_sandbox.Evidence.to_json (Tools.Shell.Output.enforcement output)
        );
      ])

let fetch_format = function
  | Tools.Web_fetch.Input.Markdown -> "markdown"
  | Tools.Web_fetch.Input.Text -> "text"
  | Tools.Web_fetch.Input.Html -> "html"

let fetch_truncated output =
  match Tools.Web_fetch.Output.status output with
  | Tools.Web_fetch.Output.Fetched { body; _ } ->
      body.Tools.Web_fetch.Output.truncated
  | Tools.Web_fetch.Output.Http_error { preview = Some body; _ } ->
      body.Tools.Web_fetch.Output.truncated
  | Tools.Web_fetch.Output.Redirected _
  | Tools.Web_fetch.Output.Http_error { preview = None; _ } ->
      false

let fetch_status_json = function
  | Tools.Web_fetch.Output.Fetched { code; body; code_text = _ } ->
      json_obj
        [
          ("kind", Jsont.Json.string "fetched");
          ("code", Jsont.Json.int code);
          ("truncated", Jsont.Json.bool body.Tools.Web_fetch.Output.truncated);
          ( "omitted_chars",
            Jsont.Json.int body.Tools.Web_fetch.Output.omitted_chars );
        ]
  | Tools.Web_fetch.Output.Redirected { code; from_url; to_url } ->
      json_obj
        [
          ("kind", Jsont.Json.string "redirected");
          ("code", Jsont.Json.int code);
          ("from_url", Jsont.Json.string (Tools.Web.Url.to_string from_url));
          ("to_url", Jsont.Json.string (Tools.Web.Url.to_string to_url));
        ]
  | Tools.Web_fetch.Output.Http_error { code; preview; code_text = _ } ->
      json_obj
        [
          ("kind", Jsont.Json.string "http_error");
          ("code", Jsont.Json.int code);
          ("preview", Jsont.Json.bool (Option.is_some preview));
        ]

let web_fetch_json output =
  let content_type =
    match Tools.Web_fetch.Output.content_type output with
    | None -> Jsont.Json.null ()
    | Some value -> Jsont.Json.string value
  in
  json_obj
    [
      ("kind", Jsont.Json.string "fetch");
      ( "requested_url",
        Jsont.Json.string
          (Tools.Web.Url.to_string
             (Tools.Web_fetch.Output.requested_url output)) );
      ( "effective_url",
        Jsont.Json.string
          (Tools.Web.Url.to_string
             (Tools.Web_fetch.Output.effective_url output)) );
      ("content_type", content_type);
      ( "format",
        Jsont.Json.string (fetch_format (Tools.Web_fetch.Output.format output))
      );
      ("bytes_read", Jsont.Json.int (Tools.Web_fetch.Output.bytes_read output));
      ("duration_ms", Jsont.Json.int (Tools.Web_fetch.Output.duration_ms output));
      ("truncated", Jsont.Json.bool (fetch_truncated output));
      ("status", fetch_status_json (Tools.Web_fetch.Output.status output));
    ]

let search_backend = function Tools.Web_search.Output.Brave -> "brave"

let web_search_json output =
  json_obj
    [
      ("kind", Jsont.Json.string "search");
      ("query", Jsont.Json.string (Tools.Web_search.Output.query output));
      ( "backend",
        Jsont.Json.string
          (search_backend (Tools.Web_search.Output.backend output)) );
      ( "result_count",
        Jsont.Json.int (List.length (Tools.Web_search.Output.results output)) );
      ( "duration_ms",
        Jsont.Json.int (Tools.Web_search.Output.duration_ms output) );
    ]

let evidence_fields evidence =
  let changed = changed_files_of_evidence evidence in
  let changed_fields =
    match changed with
    | [] -> []
    | rows -> [ ("changed_files", Jsont.Json.list rows) ]
  in
  let process_fields =
    match evidence with
    | Tools.Evidence.Shell output -> [ ("process", process_json output) ]
    | Tools.Evidence.Web_fetch output -> [ ("web", web_fetch_json output) ]
    | Tools.Evidence.Web_search output -> [ ("web", web_search_json output) ]
    | Tools.Evidence.Read_file _ | Tools.Evidence.Mutation _
    | Tools.Evidence.Search_text _ | Tools.Evidence.Glob _
    | Tools.Evidence.Ocaml_eval _ | Tools.Evidence.Ocaml_dune_describe _
    | Tools.Evidence.Ocaml_dune_diagnostics _
    | Tools.Evidence.Ocaml_find_definitions _
    | Tools.Evidence.Ocaml_find_references _
    | Tools.Evidence.Ocaml_search_expressions _ | Tools.Evidence.Ocaml_docs _
    | Tools.Evidence.Ocaml_type_at _ ->
        []
  in
  changed_fields @ process_fields

let to_json = function
  | Started { execution } -> ("tool.started", execution_fields execution)
  | Finished { execution; result } -> (
      let output = Spice_tool.Result.output result in
      let evidence = Option.bind output Tools.Evidence.of_output in
      let truncated =
        match output with
        | None -> []
        | Some output ->
            [
              ("truncated", Jsont.Json.bool (Spice_tool.Output.truncated output));
            ]
      in
      ( "tool.finished",
        execution_fields execution @ status_fields result @ truncated
        @
        match evidence with
        | None -> []
        | Some evidence -> evidence_fields evidence ))
  | Workspace_changed { execution; checkpoint; changes; total } ->
      let checkpoint_fields =
        match checkpoint with
        | None -> []
        | Some checkpoint ->
            [
              ( "checkpoint_id",
                Jsont.Json.string
                  (Spice_mutation.Checkpoint.Id.to_string
                     (Spice_mutation.Checkpoint.id checkpoint)) );
            ]
      in
      let revertable =
        List.for_all
          (fun change ->
            match Spice_mutation.Change.revertability change with
            | Spice_mutation.Change.Revertable -> true
            | Spice_mutation.Change.Not_revertable _ -> false)
          changes
      in
      ( "workspace.changed",
        execution_fields execution @ checkpoint_fields
        @ [
            ("files", Jsont.Json.int total.Spice_mutation.Change.files);
            ( "additions",
              Jsont.Json.int total.Spice_mutation.Change.total_additions );
            ( "deletions",
              Jsont.Json.int total.Spice_mutation.Change.total_deletions );
            ("revertable", Jsont.Json.bool revertable);
          ] )

(* Human rendering *)

let quote text = "\"" ^ text ^ "\""
let seconds ms = Printf.sprintf "%.1fs" (float_of_int ms /. 1000.0)

let tool_lifecycle_indicator = function
  | `Running -> "•"
  | `Completed -> "✓"
  | `Failed -> "✗"
  | `Interrupted -> "!"

let change_summary (change : Spice_tools.Receipt.change) =
  let path = W.Path.display change.Spice_tools.Receipt.path in
  match change.Spice_tools.Receipt.op with
  | Spice_tools.Receipt.Create -> "A " ^ path
  | Spice_tools.Receipt.Modify -> "M " ^ path
  | Spice_tools.Receipt.Delete -> "D " ^ path
  | Spice_tools.Receipt.Move { from } ->
      "R " ^ W.Path.display from ^ " -> " ^ path

let mutation_summary receipt =
  if Spice_tools.Receipt.is_empty receipt then "unchanged"
  else
    String.concat " "
      (List.map change_summary (Spice_tools.Receipt.changes receipt))

let truncated_note output =
  let note stream label =
    match (stream : Tools.Shell.Output.stream) with
    | Tools.Shell.Output.Complete _ -> None
    | Tools.Shell.Output.Truncated { omitted_bytes; _ } ->
        Some
          (Printf.sprintf "%s truncated, %d bytes omitted" label omitted_bytes)
  in
  match
    List.filter_map Fun.id
      [
        note (Tools.Shell.Output.stdout output) "stdout";
        note (Tools.Shell.Output.stderr output) "stderr";
      ]
  with
  | [] -> ""
  | notes -> " (" ^ String.concat "; " notes ^ ")"

let shell_status_summary output =
  match Tools.Shell.Output.status output with
  | Tools.Shell.Output.Exited code ->
      Printf.sprintf "exited %d in %s" code
        (seconds (Tools.Shell.Output.duration_ms output))
  | Tools.Shell.Output.Signaled signal -> Printf.sprintf "signaled %d" signal
  | Tools.Shell.Output.Timed_out { timeout_ms } ->
      Printf.sprintf "timed out after %dms" timeout_ms
  | Tools.Shell.Output.Cancelled -> "cancelled"
  | Tools.Shell.Output.Failed_to_start message -> "failed to start: " ^ message

(* [target] and [summary] feed the line
   [tool <name> <target> <status>: <summary>]. *)

let evidence_target = function
  | Tools.Evidence.Read_file output ->
      Some (W.Path.display (Tools.Read_file.Output.path output))
  | Tools.Evidence.Mutation { receipt; _ } -> (
      match Spice_tools.Receipt.paths receipt with
      | [] -> None
      | path :: _ -> Some (W.Path.display path))
  | Tools.Evidence.Search_text output ->
      Some (quote (Tools.Search_text.Output.pattern output))
  | Tools.Evidence.Glob output ->
      Some (quote (Tools.Glob.Output.pattern output))
  | Tools.Evidence.Ocaml_eval output ->
      Some (W.Path.display (Tools.Ocaml_eval.Output.dir output))
  | Tools.Evidence.Ocaml_dune_describe _ -> Some "dune describe"
  | Tools.Evidence.Ocaml_dune_diagnostics output ->
      Some (Tools.Ocaml_dune_diagnostics.Output.endpoint_text output)
  | Tools.Evidence.Ocaml_find_definitions output ->
      Some
        (Tools.Ocaml_find_definitions.Input.path
           (Tools.Ocaml_find_definitions.Output.input output))
  | Tools.Evidence.Ocaml_find_references output ->
      Some
        (Tools.Ocaml_find_references.Input.path
           (Tools.Ocaml_find_references.Output.query output))
  | Tools.Evidence.Ocaml_search_expressions output ->
      Some (quote (Tools.Ocaml_search_expressions.Output.pattern output))
  | Tools.Evidence.Ocaml_docs output ->
      Some (Tools.Ocaml_docs.Output.source_path output)
  | Tools.Evidence.Ocaml_type_at output ->
      Some (W.Path.display (Tools.Ocaml_type_at.Output.path output))
  | Tools.Evidence.Shell output ->
      Some (quote (Tools.Shell.Output.command output))
  | Tools.Evidence.Web_fetch output ->
      Some
        (Tools.Web.Url.to_string (Tools.Web_fetch.Output.requested_url output))
  | Tools.Evidence.Web_search output ->
      Some (quote (Tools.Web_search.Output.query output))

let evidence_summary = function
  | Tools.Evidence.Read_file output -> (
      match (output : Tools.Read_file.Output.t) with
      | Tools.Read_file.Output.Read read ->
          Printf.sprintf "%d lines" read.Tools.Read_file.Output.returned_lines
      | Tools.Read_file.Output.Unchanged _ -> "unchanged"
      | Tools.Read_file.Output.Listing listing ->
          Printf.sprintf "%d entries"
            (List.length listing.Tools.Read_file.Output.entries))
  | Tools.Evidence.Mutation { receipt; _ } -> mutation_summary receipt
  | Tools.Evidence.Search_text output -> (
      match Tools.Search_text.Output.result output with
      | Tools.Search_text.Output.Files paths ->
          Printf.sprintf "%d files" (List.length paths)
      | Tools.Search_text.Output.Count count ->
          Printf.sprintf "%d files"
            (List.length count.Tools.Search_text.Output.files)
      | Tools.Search_text.Output.Matches spans ->
          Printf.sprintf "%d matches" (List.length spans))
  | Tools.Evidence.Glob output ->
      Printf.sprintf "%d files" (Tools.Glob.Output.returned_files output)
  | Tools.Evidence.Ocaml_eval output -> (
      match Tools.Ocaml_eval.Output.status output with
      | Tools.Ocaml_eval.Output.Exited code ->
          Printf.sprintf "%s exited %d"
            (match Tools.Ocaml_eval.Output.stage output with
            | Tools.Ocaml_eval.Output.Dune_top -> "dune top"
            | Tools.Ocaml_eval.Output.Eval -> "eval")
            code
      | Tools.Ocaml_eval.Output.Signaled signal ->
          Printf.sprintf "signaled %d" signal
      | Tools.Ocaml_eval.Output.Timed_out { timeout_ms } ->
          Printf.sprintf "timed out after %dms" timeout_ms
      | Tools.Ocaml_eval.Output.Cancelled -> "cancelled"
      | Tools.Ocaml_eval.Output.Failed_to_start message ->
          "failed to start: " ^ message)
  | Tools.Evidence.Ocaml_dune_describe output ->
      Printf.sprintf "%d components, %d tests"
        (Tools.Ocaml_dune_describe.Output.component_count output)
        (Tools.Ocaml_dune_describe.Output.test_count output)
  | Tools.Evidence.Ocaml_dune_diagnostics output ->
      Printf.sprintf "%d diagnostics"
        (Tools.Ocaml_dune_diagnostics.Output.diagnostic_count output)
  | Tools.Evidence.Ocaml_find_definitions output ->
      Printf.sprintf "%d definitions"
        (Tools.Ocaml_find_definitions.Output.definition_count output)
  | Tools.Evidence.Ocaml_find_references output ->
      Printf.sprintf "%d references"
        (Tools.Ocaml_find_references.Output.total_count output)
  | Tools.Evidence.Ocaml_search_expressions output -> (
      let findings =
        Printf.sprintf "%d findings"
          (Tools.Ocaml_search_expressions.Output.total_results output)
      in
      match Tools.Ocaml_search_expressions.Output.skipped output with
      | [] -> findings
      | skipped ->
          Printf.sprintf "%s, %d files skipped" findings (List.length skipped))
  | Tools.Evidence.Ocaml_docs output ->
      Printf.sprintf "%d items (%s)"
        (List.length (Tools.Ocaml_docs.Output.items output))
        (Tools.Ocaml_docs.Output.provenance output)
  | Tools.Evidence.Ocaml_type_at output -> (
      match Tools.Ocaml_type_at.Output.frames output with
      | [] -> "no type"
      | frame :: _ ->
          let type_string = Tools.Ocaml_type_at.Frame.type_string frame in
          if String.length type_string <= 60 then type_string
          else String.sub type_string 0 57 ^ "...")
  | Tools.Evidence.Shell output ->
      shell_status_summary output ^ truncated_note output
  | Tools.Evidence.Web_fetch output -> (
      match Tools.Web_fetch.Output.status output with
      | Tools.Web_fetch.Output.Fetched { body; _ } ->
          Printf.sprintf "%s; %s; %d bytes%s"
            (Option.value
               (Tools.Web_fetch.Output.content_type output)
               ~default:"unknown content-type")
            (fetch_format (Tools.Web_fetch.Output.format output))
            (Tools.Web_fetch.Output.bytes_read output)
            (if body.Tools.Web_fetch.Output.truncated then " (truncated)"
             else "")
      | Tools.Web_fetch.Output.Redirected { to_url; _ } ->
          "redirected: " ^ Tools.Web.Url.to_string to_url
      | Tools.Web_fetch.Output.Http_error { code; _ } ->
          Printf.sprintf "http error %d" code)
  | Tools.Evidence.Web_search output ->
      Printf.sprintf "%d results"
        (List.length (Tools.Web_search.Output.results output))

let to_human = function
  | Started { execution } ->
      let call = Session.Tool_claim.Started.call execution in
      Some
        (Printf.sprintf "%s tool %s running"
           (tool_lifecycle_indicator `Running)
           (Tool_call.name call))
  | Workspace_changed _ -> None
  | Finished { execution; result } -> (
      let call = Session.Tool_claim.Started.call execution in
      let name = Tool_call.name call in
      let output = Spice_tool.Result.output result in
      let evidence = Option.bind output Tools.Evidence.of_output in
      let target =
        match Option.bind evidence evidence_target with
        | None -> ""
        | Some target -> " " ^ target
      in
      match Spice_tool.Result.status result with
      | Spice_tool.Result.Completed -> (
          match evidence with
          | Some (Tools.Evidence.Shell _ as evidence) ->
              Some
                (Printf.sprintf "%s tool %s%s %s"
                   (tool_lifecycle_indicator `Completed)
                   name target
                   (evidence_summary evidence))
          | Some evidence ->
              Some
                (Printf.sprintf "%s tool %s%s completed: %s"
                   (tool_lifecycle_indicator `Completed)
                   name target
                   (evidence_summary evidence))
          | None ->
              Some
                (Printf.sprintf "%s tool %s%s completed"
                   (tool_lifecycle_indicator `Completed)
                   name target))
      | Spice_tool.Result.Failed { message; _ } ->
          Some
            (Printf.sprintf "%s tool %s%s failed: %s"
               (tool_lifecycle_indicator `Failed)
               name target message)
      | Spice_tool.Result.Interrupted { reason; _ } ->
          Some
            (Printf.sprintf "%s tool %s%s interrupted: %s"
               (tool_lifecycle_indicator `Interrupted)
               name target reason))
