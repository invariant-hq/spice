(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
module Config = Spice_host.Config
module Context = Spice_host.Context
module Source = Spice_host.Context.Source

(* Debug surfaces print model-visible facts: [context] shows workspace
   context discovery, [prompt] the projected prelude, [tools] the tool
   declarations of the same run config [spice run] assembles. *)

(* Workspace facts combine requested policy from [Config] (with origins) and
   discovered facts from the [Context] snapshot. *)

let origin_suffix config key =
  match Config.origin key config with
  | None -> ""
  | Some origin -> (
      match Config.Origin.source origin with
      | Config.Source.Default _ -> " (default)"
      | Config.Source.User _ | Config.Source.Project _
      | Config.Source.Project_local _ | Config.Source.Extra_file _ ->
          " (config)"
      | Config.Source.Env _ -> " (env)"
      | Config.Source.Override -> " (flag)")

let enabled_string enabled = if enabled then "enabled" else "disabled"

let root_display config context =
  let cwd = Context.cwd context in
  let root = Context.root context in
  if Spice_path.Abs.equal root cwd then
    Spice_path.Abs.to_string (Config.cwd config)
  else Spice_path.Abs.reach ~from:cwd root

let print_workspace config context =
  let instructions = Config.instructions config in
  stdout_printf "Workspace:\n";
  stdout_printf "  cwd: %s\n" (Spice_path.Abs.to_string (Config.cwd config));
  stdout_printf "  root: %s\n" (root_display config context);
  stdout_printf "  root marker: %s\n"
    (Option.value (Context.root_marker context) ~default:"(none)");
  stdout_printf "  global instructions: %s%s\n"
    (enabled_string (Config.Instructions.global instructions))
    (origin_suffix config Config.Field.instructions_global);
  stdout_printf "  project instructions: %s%s\n"
    (enabled_string (Config.Instructions.project instructions))
    (origin_suffix config Config.Field.instructions_project);
  stdout_printf "  claude compatibility: %s%s\n"
    (enabled_string (Config.Instructions.claude_md instructions))
    (origin_suffix config Config.Field.instructions_claude_md);
  stdout_printf "  project budget: %d bytes (%d used)\n"
    (Config.Instructions.project_max_bytes instructions)
    (Context.budget_used context)

let source_label source =
  let filename =
    Option.value
      (Spice_path.Abs.basename (Source.path source))
      ~default:(Source.display_path source)
  in
  Source.kind_string (Source.kind source)
  ^ " " ^ filename ^ " " ^ Source.display_path source

let print_sources context =
  let active, inactive =
    List.partition
      (fun source ->
        match Source.status source with
        | Source.Active _ -> true
        | Source.Shadowed _ | Source.Disabled _ | Source.Not_activated
        | Source.Skipped _ ->
            false)
      (Context.sources context)
  in
  stdout_printf "Active instruction sources:\n";
  (match active with
  | [] -> stdout_printf "  (none)\n"
  | active ->
      List.iteri
        (fun index source ->
          stdout_printf "  [%d] %s\n" (index + 1) (source_label source);
          match Source.status source with
          | Source.Active content ->
              stdout_printf "      bytes: %d included: %d digest: %s\n"
                content.Source.bytes content.Source.included_bytes
                content.Source.digest
          | Source.Shadowed _ | Source.Disabled _ | Source.Not_activated
          | Source.Skipped _ ->
              ())
        active);
  stdout_printf "\n";
  stdout_printf "Inactive instruction sources:\n";
  match inactive with
  | [] -> stdout_printf "  (none)\n"
  | inactive ->
      List.iter
        (fun source ->
          let status = Source.status source in
          stdout_printf "  %s %s %s\n"
            (Source.display_path source)
            (Source.state_string status)
            (Option.value (Source.reason_string status) ~default:""))
        inactive

let print_warnings warnings =
  stdout_printf "Warnings:\n";
  match warnings with
  | [] -> stdout_printf "  (none)\n"
  | warnings -> List.iter (stdout_printf "  %s\n") warnings

(* JSON envelopes. The CLI owns the envelope shape; the library owns the
   per-fact codecs. *)

let origin_string config key =
  match Config.origin key config with
  | None -> "default"
  | Some origin -> (
      match Config.Origin.source origin with
      | Config.Source.Default _ -> "default"
      | Config.Source.User _ | Config.Source.Project _
      | Config.Source.Project_local _ | Config.Source.Extra_file _ ->
          "config"
      | Config.Source.Env _ -> "env"
      | Config.Source.Override -> "flag")

let enablement_json config key enabled =
  json_obj
    [
      ("enabled", Jsont.Json.bool enabled);
      ("origin", Jsont.Json.string (origin_string config key));
    ]

let nested_scan_string = function
  | `Off -> "off"
  | `Complete -> "complete"
  | `Capped -> "capped"

let workspace_json config context =
  let instructions = Config.instructions config in
  json_obj
    [
      ("cwd", Jsont.Json.string (Spice_path.Abs.to_string (Config.cwd config)));
      ( "cwd_path",
        Jsont.Json.string (Spice_path.Abs.to_string (Context.cwd context)) );
      ("root", Jsont.Json.string (root_display config context));
      ( "root_path",
        Jsont.Json.string (Spice_path.Abs.to_string (Context.root context)) );
      ( "root_marker",
        match Context.root_marker context with
        | None -> Jsont.Json.null ()
        | Some marker -> Jsont.Json.string marker );
      ( "global_instructions",
        enablement_json config Config.Field.instructions_global
          (Config.Instructions.global instructions) );
      ( "project_instructions",
        enablement_json config Config.Field.instructions_project
          (Config.Instructions.project instructions) );
      ( "claude_compatibility",
        enablement_json config Config.Field.instructions_claude_md
          (Config.Instructions.claude_md instructions) );
      ( "budget",
        json_obj
          [
            ( "total",
              Jsont.Json.int
                (Config.Instructions.project_max_bytes instructions) );
            ("used", Jsont.Json.int (Context.budget_used context));
          ] );
      ( "nested_scan",
        Jsont.Json.string (nested_scan_string (Context.nested_scan context)) );
    ]

let warnings_json context =
  json_list
    (List.map (fun value -> Jsont.Json.string value) (Context.warnings context))

let projection_json context =
  json_obj
    [ ("rendered_digest", Jsont.Json.string (Context.rendered_digest context)) ]

let show_json config context =
  json_envelope ~type_:"context_show"
    [
      ("workspace", workspace_json config context);
      ("sources", json_list (List.map Source.to_json (Context.sources context)));
      ("projection", projection_json context);
      ("warnings", warnings_json context);
    ]

(* Mode preludes are system or developer instructions by construction; any
   other message kind here is a programmer bug, reported loudly. *)
let mode_message_parts message =
  match message with
  | Spice_llm.Message.System text -> ("system", text)
  | Spice_llm.Message.Developer text -> ("developer", text)
  | Spice_llm.Message.User _ | Spice_llm.Message.Assistant _
  | Spice_llm.Message.Tool_result _ ->
      assert false

let mode_message_json message =
  let role, text = mode_message_parts message in
  json_obj
    [ ("role", Jsont.Json.string role); ("text", Jsont.Json.string text) ]

let prompt_json mode context =
  json_envelope ~type_:"context_prompt"
    [
      ("mode", Jsont.Json.string (Spice_protocol.Mode.to_string mode));
      ("fragments", json_list (Context.projection_json context));
      ( "mode_messages",
        json_list
          (List.map mode_message_json
             (Spice_protocol.Mode.prelude_messages mode)) );
      ("projection", projection_json context);
    ]

let with_context ?cwd ?(nested_scan = false) overrides f =
  Eio_main.run @@ fun stdenv ->
  match Config.load ~stdenv ?cwd ~overrides () with
  | Error error -> Runtime_error (Config.Error.message error)
  | Ok config -> (
      match Context.load ~stdenv ~nested_scan config with
      | Error error -> Runtime_error (Spice_host.Host.Error.message error)
      | Ok context -> f config context)

let show json overrides cwd =
  with_context ?cwd ~nested_scan:true overrides @@ fun config context ->
  if json then stdout_printf "%s\n" (json_string (show_json config context))
  else begin
    print_workspace config context;
    stdout_printf "\n";
    print_sources context;
    stdout_printf "\n";
    stdout_printf "Projection:\n  rendered digest: %s\n"
      (Context.rendered_digest context);
    stdout_printf "\n";
    print_warnings (Context.warnings context)
  end;
  Success

let prompt json mode overrides cwd =
  with_context ?cwd overrides @@ fun _config context ->
  if json then stdout_printf "%s\n" (json_string (prompt_json mode context))
  else begin
    List.iter (stdout_printf "%s\n") (Context.projection_texts context);
    List.iter
      (fun message -> stdout_printf "%s\n" (snd (mode_message_parts message)))
      (Spice_protocol.Mode.prelude_messages mode)
  end;
  Success

(* [spice debug tools] prints the declarations of the same run config [spice
   exec] assembles, so the snapshot cannot drift from what requests send. *)

(* [spice debug tools] resolves an editor family from a model exactly as a run
   does. With [--model] it resolves that selector (a failure is surfaced);
   without, it resolves the host's main model, and when none resolves (no
   credentials in the snapshot environment) it falls back to no model, i.e. the
   string-replace family. *)
let resolve_debug_model ~stdenv host raw =
  match raw with
  | Some input -> (
      match Spice_host.Models.resolve (Spice_host.Host.catalog host) input with
      | Ok choice -> Ok (Some (Spice_host.Models.Model_choice.model choice))
      | Error error -> Error (`Host error))
  | None -> (
      match
        Spice_host.Models.choose
          ~connected:(Spice_host.Account.connectivity ~stdenv host)
          host Spice_host.Models.Model_choice.Main
      with
      | Ok choice -> Ok (Some (Spice_host.Models.Model_choice.model choice))
      | Error _ -> Ok None)

(* The catalog snapshot resolves a fixed read-only posture: no trust or
   backend requirement gates a description of the tool declarations, and the
   read-only catalog is the maximal one minus mutating tools, which the
   printout still includes via the explicit workspace-write posture below.

   No [project_source] is threaded here: the debug snapshot runs a fresh
   [dune describe] rather than a boot snapshot, which fails fast under a watch
   — accepted for a debug command. *)
let declarations ~sw ~stdenv host ~model mode =
  let open Result.Syntax in
  let* workspace =
    Spice_host.workspace host |> Result.map_error (fun error -> `Host error)
  in
  let effective =
    resolve_sandbox host ~workspace
      {
        sandbox_flag = Some Spice_host.Sandbox.Mode.Workspace_write;
        require_sandbox = false;
      }
  in
  let* context =
    host_context ~stdenv host |> Result.map_error (fun error -> `Host error)
  in
  let* prelude =
    mode_prelude context mode |> Result.map_error (fun error -> `Host error)
  in
  let skills = host_skills ~stdenv host in
  let dune =
    Spice_ocaml_dune.Rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
      ~net:(Eio.Stdenv.net stdenv) ~workspace ()
  in
  let cwd = Spice_host.Context.eio_cwd ~stdenv context in
  (* The debug snapshot mirrors a run's flag-gated anchored-edit catalog; the
     one-shot resolver only shapes the printed declarations. *)
  let anchors =
    if
      Spice_host.Config.Tools.anchored_edits
        (Spice_host.Config.tools (Spice_host.Host.config host))
    then
      Some
        (Spice_tools.Anchor_tracker.resolver
           (Spice_tools.Anchor_tracker.create ~seed:"debug" ()))
    else None
  in
  let tools =
    Spice_host.Toolset.make ~sw ~stdenv host ?model ~workspace
      ~sandbox:effective ~skills ~cwd
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ?anchors ~dune ()
    |> Spice_protocol.Contract.filter_tools (Spice_protocol.Mode.contract mode)
  in
  let permission = permission_args host None in
  let policy =
    Spice_protocol.Contract.policy
      (Spice_protocol.Mode.contract mode)
      ~configured:(Spice_host.Permission.Run.policy permission)
  in
  let run =
    Spice_session.Run.Config.make ~tools
      ~host_tools:
        (List.map Spice_protocol.Call.Kind.tool
           (Spice_protocol.Mode.host_tools mode))
      ~policy ~prelude ()
  in
  Ok (Spice_session.Run.Config.declarations run)

let tools_json mode ~editor ~reason declarations =
  json_envelope ~type_:"debug_tools"
    [
      ("mode", Jsont.Json.string (Spice_protocol.Mode.to_string mode));
      ("editor_family", Jsont.Json.string (Spice_tools.Editor.to_string editor));
      ( "editor_reason",
        Jsont.Json.string (Spice_host.Toolset.editor_reason_to_string reason) );
      ( "tools",
        json_list (List.map (json_encode Spice_llm.Tool.jsont) declarations) );
    ]

let print_declaration declaration =
  stdout_printf "## %s\n\n" (Spice_llm.Tool.name declaration);
  (match Spice_llm.Tool.description declaration with
  | None -> ()
  | Some description -> stdout_printf "%s\n\n" description);
  stdout_printf "Input schema: %s\n"
    (json_string (Spice_llm.Tool.input_schema declaration))

let tools json model_raw mode overrides cwd =
  with_host ?cwd ~overrides @@ fun ~stdenv host ->
  Eio.Switch.run @@ fun sw ->
  match resolve_debug_model ~stdenv host model_raw with
  | Error (`Host error) -> Runtime_error (Spice_host.Host.Error.message error)
  | Ok model -> (
      (* Report the editor family and why it was chosen so the snapshot is
         honest evidence of the predicate, not a silent default. *)
      let editor, reason = Spice_host.Toolset.editor_decision host model in
      match declarations ~sw ~stdenv host ~model mode with
      | Error (`Host error) ->
          Runtime_error (Spice_host.Host.Error.message error)
      | Error (`Runtime message) -> Runtime_error message
      | Ok declarations ->
          if json then
            stdout_printf "%s\n"
              (json_string (tools_json mode ~editor ~reason declarations))
          else begin
            stdout_printf "Editor family: %s (%s)\n\n"
              (Spice_tools.Editor.to_string editor)
              (Spice_host.Toolset.editor_reason_to_string reason);
            List.iteri
              (fun index declaration ->
                if index > 0 then stdout_printf "\n";
                print_declaration declaration)
              declarations
          end;
          Success)

(* [spice debug model] prints every model-conditioning decision with its
   provenance, using the same resolvers a run uses. Each row is
   [axis: value (reason)] so a surprising catalog or request can be traced
   to the declared metadata, the config override, or the fallback that
   produced it. *)
let decision_json ~value ~reason =
  json_obj
    [ ("value", Jsont.Json.string value); ("reason", Jsont.Json.string reason) ]

let model_report json model_raw overrides cwd =
  with_host ?cwd ~overrides @@ fun ~stdenv host ->
  match resolve_debug_model ~stdenv host model_raw with
  | Error (`Host error) -> Runtime_error (Spice_host.Host.Error.message error)
  | Ok resolved ->
      let model_id =
        match resolved with
        | None -> "none"
        | Some model -> Spice_provider.Model.id model
      in
      let editor, editor_reason =
        Spice_host.Toolset.editor_decision host resolved
      in
      let editor_value = Spice_tools.Editor.to_string editor in
      let editor_reason =
        Spice_host.Toolset.editor_reason_to_string editor_reason
      in
      let reasoning_value, reasoning_reason =
        match resolved with
        | None -> ("none", "no model resolved")
        | Some model -> (
            match Spice_provider.Model.default_reasoning model with
            | Some effort ->
                ( Spice_llm.Request.Options.Reasoning_effort.to_string effort,
                  "declared default" )
            | None -> ("none", "no declared default"))
      in
      let compaction_value, compaction_reason =
        match resolved with
        | None -> ("disabled", "no model resolved")
        | Some model ->
            ( (match Spice_host.Compactor.Policy.auto_limit_of_model model with
              | Some limit -> string_of_int limit
              | None -> "disabled"),
              Spice_host.Compactor.Policy.auto_limit_reason model )
      in
      if json then
        stdout_printf "%s\n"
          (json_string
             (json_envelope ~type_:"debug_model"
                [
                  ("model", Jsont.Json.string model_id);
                  ( "decisions",
                    json_obj
                      [
                        ( "editor",
                          decision_json ~value:editor_value
                            ~reason:editor_reason );
                        ( "reasoning",
                          decision_json ~value:reasoning_value
                            ~reason:reasoning_reason );
                        ( "compaction",
                          decision_json ~value:compaction_value
                            ~reason:compaction_reason );
                      ] );
                ]))
      else begin
        stdout_printf "Model: %s\n" model_id;
        stdout_printf "editor: %s (%s)\n" editor_value editor_reason;
        stdout_printf "reasoning: %s (%s)\n" reasoning_value reasoning_reason;
        stdout_printf "compaction: %s (%s)\n" compaction_value compaction_reason
      end;
      Success

(* Commands *)

let json_flag =
  Cli_arg.json_flag ()

let cwd_arg =
  Cli_arg.cwd ()

let model_arg =
  Cli_arg.model_opt
    ~doc:
      "Resolve the tool catalog for MODEL (a provider/model selector). The model \
       determines the file-mutation editor family. Defaults to the host's main \
       model; when no model resolves the string-replace editor family is used."
    ()

let context_command =
  CCmd.v
    (CCmd.info "context" ~doc:"Show active workspace context." ~exits)
    (exit_term
       CTerm.(const show $ json_flag $ Cli_arg.instruction_overrides $ cwd_arg))

let prompt_command =
  CCmd.v
    (CCmd.info "prompt"
       ~doc:"Print the exact model-visible context for the next request." ~exits)
    (exit_term
       CTerm.(
         const prompt $ json_flag $ Cli_arg.workflow_mode
         $ Cli_arg.instruction_overrides $ cwd_arg))

let tools_command =
  CCmd.v
    (CCmd.info "tools"
       ~doc:"Print the model-visible tool declarations for a run." ~exits)
    (exit_term
       CTerm.(
         const tools $ json_flag $ model_arg $ Cli_arg.workflow_mode
         $ Cli_arg.instruction_overrides $ cwd_arg))

let model_command =
  CCmd.v
    (CCmd.info "model"
       ~doc:
         "Print every model-conditioning decision (value and reason) for a \
          resolved model."
       ~exits)
    (exit_term
       CTerm.(
         const model_report $ json_flag $ model_arg
         $ Cli_arg.instruction_overrides $ cwd_arg))

let group =
  CCmd.group
    (CCmd.info "debug" ~doc:"Inspect model-visible prompts and internal state."
       ~docs:s_diagnostic_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Prints exactly what a run would assemble: the workspace context, \
              the model-visible prompt, the tool declarations, and the \
              model-conditioning decisions. Useful for diagnosing instruction \
              and context issues without spending a model call.";
         ]
       ~exits)
    [ context_command; prompt_command; tools_command; model_command ]
