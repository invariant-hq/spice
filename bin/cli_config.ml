(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
open Result.Syntax
module Config = Spice_host.Config
module Config_file = Config.Config_file

let config_error_text error =
  Spice_diagnostic.to_string (Config.Error.diagnostic error)

let config_keys =
  [
    ( "model",
      "Main model selector, for example $(b,openai/gpt-5). Must not be empty."
    );
    ( "small_model",
      "Small-model selector used for cheaper helper tasks. Must not be empty."
    );
    ( "reasoning",
      "Default reasoning effort: $(b,none), $(b,minimal), $(b,low), \
       $(b,medium), $(b,high), $(b,xhigh), or $(b,max)." );
    ( "tui.thinking",
      "Whether the TUI shows thinking summaries: $(b,true) or $(b,false)." );
    ( "providers.$(i,ID).base_url",
      "API root override for provider $(i,ID). Provider ids are lowercase \
       ASCII slugs." );
    ("run.max_steps", "Positive integer maximum for model/tool cycles.");
    ( "permission.mode",
      "Durable permission preset: $(b,default), $(b,accept-edits), or \
       $(b,plan). $(b,bypass) is available only through the per-run \
       $(b,--permission-mode) flag." );
    ("shell", "Shell program used for shell commands. Must not be empty.");
    ( "instructions.global",
      "Whether the global $(b,AGENTS.md) in the config home is loaded: \
       $(b,true) or $(b,false)." );
    ( "instructions.project",
      "Whether project instruction files are loaded: $(b,true) or $(b,false)."
    );
    ( "instructions.claude_md",
      "Whether $(b,CLAUDE.md) compatibility files are loaded: $(b,true) or \
       $(b,false)." );
    ( "instructions.project_max_bytes",
      "Positive integer byte budget for project instruction text." );
  ]

let config_keys_man =
  `S "CONFIG KEYS"
  :: `P "Supported keys for $(b,get), $(b,set), and $(b,unset):"
  :: List.map (fun (key, doc) -> `I (key, doc)) config_keys

let target_man =
  [
    `S "CONFIG TARGETS";
    `P
      "Editing commands write the user config by default. Use $(b,--project) \
       for shared project config, or $(b,--project-local) for gitignored \
       project-local config.";
  ]

let precedence_man =
  [
    `S "CONFIG PRECEDENCE";
    `P
      "Effective values are resolved in increasing precedence: the user config \
       file, the project config file, the project-local config file, the \
       $(b,SPICE_CONFIG) extra config file, $(b,SPICE_*) environment \
       overrides, then runtime overrides such as run flags. The two workspace \
       files activate only after $(b,spice trust); even then they are reduced \
       to the project allowlist, and dropped inputs are reported as \
       diagnostics by $(b,--origins).";
  ]

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> failwith message

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_null_or_string = function
  | None -> Jsont.Json.null ()
  | Some value -> Jsont.Json.string value

let json_null_or_int = function
  | None -> Jsont.Json.null ()
  | Some value -> Jsont.Json.int value

let json_encode codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failwith message

let with_config f =
  Eio_main.run @@ fun stdenv ->
  let process_env = Spice_host.Env.current () in
  match Config.load ~stdenv ~process_env () with
  | Error error -> Runtime_error (config_error_text error)
  | Ok config -> f ~stdenv config

let with_files f =
  Eio_main.run @@ fun stdenv ->
  match Config_file.discover ~stdenv () with
  | Error error -> Runtime_error (config_error_text error)
  | Ok files -> f ~stdenv files

let path file =
  with_files @@ fun ~stdenv:_ files ->
  stdout_printf "%s\n" (Config_file.path files file |> Spice_path.Abs.to_string);
  Success

let provider_json (provider, base_url) =
  ( Spice_llm.Provider.id provider,
    json_obj [ ("base_url", json_null_or_string (Some base_url)) ] )

let source_string source = Format.asprintf "%a" Config.Source.pp source

let show_json config =
  let models = Config.models config in
  let runtime = Config.runtime config in
  let notices = Config.notices config in
  let permissions = Config.permissions config in
  let instructions = Config.instructions config in
  let skills = Config.skills config in
  let tools = Config.tools config in
  let web = Config.web config in
  let tui = Config.tui config in
  json_obj
    [
      ("cwd", Jsont.Json.string (Spice_path.Abs.to_string (Config.cwd config)));
      ( "project_root",
        Jsont.Json.string
          (Spice_path.Abs.to_string (Config.project_root config)) );
      ( "workspace_trust",
        Jsont.Json.string
          (Config.workspace_trust config |> Spice_host.Trust.status
         |> Spice_host.Trust.status_to_string) );
      ( "data_home",
        Jsont.Json.string (Spice_path.Abs.to_string (Config.data_home config))
      );
      ( "state_home",
        Jsont.Json.string (Spice_path.Abs.to_string (Config.state_home config))
      );
      ( "auth_store_path",
        Jsont.Json.string
          (Spice_path.Abs.to_string (Config.auth_store_path config)) );
      ( "files",
        json_obj
          [
            ( "user",
              Jsont.Json.string
                (Config_file.user (Config.files config)
                |> Spice_path.Abs.to_string) );
            ( "project",
              Jsont.Json.string
                (Config_file.project (Config.files config)
                |> Spice_path.Abs.to_string) );
            ( "project_local",
              Jsont.Json.string
                (Config_file.project_local (Config.files config)
                |> Spice_path.Abs.to_string) );
          ] );
      ("model", json_null_or_string (Config.Models.main models));
      ("small_model", json_null_or_string (Config.Models.small models));
      ( "reasoning",
        json_null_or_string
          (Option.map Spice_llm.Request.Options.Reasoning_effort.to_string
             (Config.Models.reasoning models)) );
      ( "run",
        json_obj
          [ ("max_steps", json_null_or_int (Config.Runtime.max_steps runtime)) ]
      );
      ( "tui",
        json_obj [ ("thinking", Jsont.Json.bool (Config.Tui.thinking tui)) ] );
      ( "notices",
        json_obj
          [
            ("fswatch", Jsont.Json.bool (Config.Notices.fswatch notices));
            ("cr_comments", Jsont.Json.bool (Config.Notices.cr_comments notices));
            ( "dune_diagnostics",
              Jsont.Json.bool (Config.Notices.dune_diagnostics notices) );
            ("dune_build", Jsont.Json.bool (Config.Notices.dune_build notices));
          ] );
      ( "permission",
        json_obj
          [
            ( "mode",
              Jsont.Json.string
                (Spice_host.Permission.Preset.to_string
                   (Config.Permissions.mode permissions)) );
          ] );
      ("shell", Jsont.Json.string (Config.Runtime.shell runtime));
      ( "instructions",
        json_obj
          [
            ("global", Jsont.Json.bool (Config.Instructions.global instructions));
            ( "project",
              Jsont.Json.bool (Config.Instructions.project instructions) );
            ( "claude_md",
              Jsont.Json.bool (Config.Instructions.claude_md instructions) );
            ( "project_max_bytes",
              Jsont.Json.int
                (Config.Instructions.project_max_bytes instructions) );
          ] );
      ( "skills",
        json_obj
          [
            ("enabled", Jsont.Json.bool (Config.Skills.enabled skills));
            ("builtin", Jsont.Json.bool (Config.Skills.builtin skills));
            ("project", Jsont.Json.bool (Config.Skills.project skills));
            ("compat", Jsont.Json.bool (Config.Skills.compat skills));
            ( "paths",
              Jsont.Json.list
                (List.map
                   (fun value -> Jsont.Json.string value)
                   (Config.Skills.paths skills)) );
            ( "catalog_max_bytes",
              Jsont.Json.int (Config.Skills.catalog_max_bytes skills) );
          ] );
      ( "tools",
        json_obj
          [
            ( "anchored_edits",
              Jsont.Json.bool (Config.Tools.anchored_edits tools) );
          ] );
      ( "web",
        json_obj
          [
            ("enabled", Jsont.Json.bool (Config.Web.enabled web));
            ( "allow_private_network",
              Jsont.Json.bool (Config.Web.allow_private_network web) );
            ("search_backend", Jsont.Json.string (Config.Web.search_backend web));
            ("fetch_max_bytes", Jsont.Json.int (Config.Web.fetch_max_bytes web));
            ( "output_max_chars",
              Jsont.Json.int (Config.Web.output_max_chars web) );
            ("timeout_ms", Jsont.Json.int (Config.Web.timeout_ms web));
            ("max_timeout_ms", Jsont.Json.int (Config.Web.max_timeout_ms web));
          ] );
      ( "providers",
        json_obj
          (List.map provider_json (Config.Models.provider_base_urls models)) );
    ]

let show_origin config field =
  match Config.origin field config with
  | None -> ()
  | Some origin ->
      stdout_printf "  source: %s\n"
        (source_string (Config.Origin.source origin));
      begin match Config.Origin.shadowed origin with
      | [] -> ()
      | shadowed ->
          stdout_printf "  overrides: %s\n"
            (shadowed |> List.map source_string |> String.concat ", ")
      end

let text_fields config =
  let open Config.Field in
  [ Any model; Any small_model; Any reasoning; Any tui_thinking ]
  @ List.map
      (fun (provider, _base_url) -> Any (provider_base_url provider))
      (Config.Models.provider_base_urls (Config.models config))
  @ [
      Any run_max_steps;
      Any permission_mode;
      Any shell;
      Any notices_fswatch;
      Any notices_cr_comments;
      Any notices_dune_diagnostics;
      Any notices_dune_build;
      Any instructions_global;
      Any instructions_project;
      Any instructions_claude_md;
      Any instructions_project_max_bytes;
      Any skills_enabled;
      Any skills_builtin;
      Any skills_project;
      Any skills_compat;
      Any skills_disabled;
      Any skills_paths;
      Any skills_catalog_max_bytes;
      Any tools_anchored_edits;
      Any web_enabled;
      Any web_allow_private_network;
      Any web_search_backend;
      Any web_fetch_max_bytes;
      Any web_output_max_chars;
      Any web_timeout_ms;
      Any web_max_timeout_ms;
    ]

let show_text ?(origins = false) config =
  let print_opt field value =
    match value with
    | None -> ()
    | Some value ->
        stdout_printf "%s=%s\n" (Config.Field.name field) value;
        if origins then show_origin config field
  in
  let trust = Config.workspace_trust config in
  stdout_printf "workspace_trust=%s\n"
    (Spice_host.Trust.status_to_string (Spice_host.Trust.status trust));
  if origins then
    stdout_printf "  source: %s\n"
      (match Spice_host.Trust.status trust with
      | Spice_host.Trust.Unknown -> "no stored decision"
      | Spice_host.Trust.Untrusted | Spice_host.Trust.Trusted ->
          "user workspace trust store");
  List.iter
    (fun (Config.Field.Any field) -> print_opt field (Config.get field config))
    (text_fields config)

let origin_entries config =
  Config.origins config
  |> List.map (fun (Config.Field.Any key, origin) ->
      (Config.Field.name key, json_encode Config.Origin.jsont origin))

let show_json_with_origins config =
  json_obj
    [
      ("schema_version", Jsont.Json.int 1);
      ("type", Jsont.Json.string "config_show");
      ("values", show_json config);
      ("origins", json_obj (origin_entries config));
      ( "diagnostics",
        Jsont.Json.list
          (List.map (json_encode Config.Warning.jsont) (Config.warnings config))
      );
    ]

let show json origins =
  with_config @@ fun ~stdenv:_ config ->
  if json then
    stdout_printf "%s\n"
      (json_string
         (if origins then show_json_with_origins config else show_json config))
  else (
    show_text ~origins config;
    if origins then
      Config.warnings config
      |> List.iter (fun diagnostic ->
          stdout_printf "diagnostic: %s\n"
            (Format.asprintf "%a" Config.Warning.pp diagnostic)));
  Success

let get_effective json field =
  with_config @@ fun ~stdenv:_ config ->
  let value = Config.get field config in
  if json then (
    stdout_printf "%s\n" (json_string (Config.json field config));
    Success)
  else
    match value with
    | Some value ->
        stdout_printf "%s\n" value;
        Success
    | None -> Runtime_error (Config.Field.name field ^ " is not set")

let get_source json source field =
  with_files @@ fun ~stdenv files ->
  match Config_file.load ~stdenv files source with
  | Error error -> Runtime_error (config_error_text error)
  | Ok layer -> (
      let value = Config_file.get field layer in
      if json then (
        stdout_printf "%s\n" (json_string (Config_file.json field layer));
        Success)
      else
        match value with
        | Some value ->
            stdout_printf "%s\n" value;
            Success
        | None -> Runtime_error (Config.Field.name field ^ " is not set"))

let get json source key =
  match key with
  | Config.Field.Any key -> (
      match source with
      | None -> get_effective json key
      | Some source -> get_source json source key)

(* Model keys share [Models.for_select] with [spice models select], so a
   selection rejected there cannot be written here. Validation uses only the
   static provider catalog: a broken config file must remain repairable by
   this very command. *)
let validate_value field value =
  if
    Config.Field.equal field Config.Field.model
    || Config.Field.equal field Config.Field.small_model
  then
    match Spice_host.Models.for_select Spice_provider_builtin.catalog value with
    | Ok model -> Ok (Spice_provider.Model.selector model)
    | Error error ->
        Error
          (Spice_diagnostic.to_string (Spice_host.Host.Error.diagnostic error))
  else Ok value

let set file field value =
  match field with
  | Config.Field.Any field -> (
      if not (Config_file.field_allowed file field) then
        Usage_error
          (Printf.sprintf
             "%s is not allowed in workspace config; allowed keys: %s"
             (Config.Field.name field)
             (String.concat ", " (Config_file.field_names file)))
      else
        match validate_value field value with
        | Error message -> Usage_error message
        | Ok value -> (
            match Config_file.set field (Some value) Config_file.empty with
            | Error error -> Usage_error (config_error_text error)
            | Ok _ -> (
                with_files @@ fun ~stdenv files ->
                let result =
                  Config_file.edit ~stdenv files file
                    ~f:(Config_file.set field (Some value))
                in
                match result with
                | Ok () -> Success
                | Error error -> Runtime_error (config_error_text error))))

let unset file field =
  match field with
  | Config.Field.Any field -> (
      with_files @@ fun ~stdenv files ->
      let result =
        Config_file.edit ~stdenv files file ~f:(Config_file.set field None)
      in
      match result with
      | Ok () -> Success
      | Error error -> Runtime_error (config_error_text error))

let init target =
  with_files @@ fun ~stdenv files ->
  match Config_file.ensure ~stdenv files target with
  | Ok () -> Success
  | Error error -> Runtime_error (config_error_text error)

let validate strict path =
  Eio_main.run @@ fun stdenv ->
  let report_errors errors =
    List.iter
      (fun error -> stderr_printf "spice: %s\n" (config_error_text error))
      errors;
    Failed
  in
  match path with
  | Some path
    when not (Eio.Path.is_file (Eio.Path.( / ) (Eio.Stdenv.fs stdenv) path)) ->
      Runtime_error (path ^ ": no such file")
  | _ -> (
      let result =
        match path with
        | Some path -> Ok (Config_file.validate_path ~stdenv ~strict path)
        | None -> (
            let* config = Config.load ~stdenv () in
            if not strict then Ok []
            else
              let files = Config.files config in
              let user_errors =
                Config_file.validate_path ~stdenv ~strict
                  (Config_file.user files |> Spice_path.Abs.to_string)
              in
              match
                Spice_host.Env.get (Config.process_env config) "SPICE_CONFIG"
              with
              | None | Some "" -> Ok user_errors
              | Some path ->
                  Ok
                    (user_errors
                    @ Config_file.validate_path ~stdenv ~strict path))
      in
      match result with
      | Ok [] ->
          stdout_printf "ok\n";
          Success
      | Ok errors -> report_errors errors
      | Error error -> Runtime_error (config_error_text error))

let path_command =
  CCmd.v
    (CCmd.info "path" ~doc:"Print a config file path." ~man:target_man ~exits)
    (exit_term CTerm.(const path $ Cli_arg.config_target))

let show_command =
  let json = Cli_arg.json_flag () in
  let origins =
    CArg.(
      value & flag
      & info [ "origins" ]
          ~doc:"Show the source of each effective config value.")
  in
  CCmd.v
    (CCmd.info "show" ~doc:"Show effective config." ~man:precedence_man ~exits)
    (exit_term CTerm.(const show $ json $ origins))

let get_command =
  let json = Cli_arg.json_flag () in
  let key =
    CArg.(required & pos 0 (some Cli_arg.config_key) None & info [] ~docv:"KEY")
  in
  CCmd.v
    (CCmd.info "get" ~doc:"Read one config value."
       ~man:
         (config_keys_man
         @ [
             `S "CONFIG SOURCES";
             `P
               "With no source flag, reads the effective configuration. Use \
                $(b,--user), $(b,--project), or $(b,--project-local) to read \
                one config file layer directly.";
           ])
       ~exits)
    (exit_term CTerm.(const get $ json $ Cli_arg.config_source $ key))

let set_command =
  let key =
    CArg.(required & pos 0 (some Cli_arg.config_key) None & info [] ~docv:"KEY")
  in
  let value =
    CArg.(required & pos 1 (some string) None & info [] ~docv:"VALUE")
  in
  CCmd.v
    (CCmd.info "set" ~doc:"Set a config value."
       ~man:(config_keys_man @ target_man)
       ~exits)
    (exit_term CTerm.(const set $ Cli_arg.config_target $ key $ value))

let unset_command =
  let key =
    CArg.(required & pos 0 (some Cli_arg.config_key) None & info [] ~docv:"KEY")
  in
  CCmd.v
    (CCmd.info "unset" ~doc:"Unset a config value."
       ~man:(config_keys_man @ target_man)
       ~exits)
    (exit_term CTerm.(const unset $ Cli_arg.config_target $ key))

let init_command =
  CCmd.v
    (CCmd.info "init" ~doc:"Create a config file." ~man:target_man ~exits)
    (exit_term CTerm.(const init $ Cli_arg.config_target))

let validate_command =
  let path = CArg.(value & pos 0 (some string) None & info [] ~docv:"PATH") in
  let strict =
    CArg.(
      value & flag
      & info [ "strict" ]
          ~doc:"Reject unknown fields instead of allowing them to be preserved.")
  in
  CCmd.v
    (CCmd.info "validate" ~doc:"Validate config JSON."
       ~man:
         [
           `S CManpage.s_description;
           `P
             "With no $(i,PATH), validates the effective configuration by \
              loading every applicable config source. With $(i,PATH), \
              validates that file as a partial config.";
         ]
       ~exits)
    (exit_term CTerm.(const validate $ strict $ path))

let group =
  CCmd.group
    (CCmd.info "config" ~doc:"Inspect and edit Spice configuration."
       ~docs:s_config_commands
       ~man:(config_keys_man @ target_man @ precedence_man)
       ~exits)
    [
      path_command;
      show_command;
      validate_command;
      get_command;
      set_command;
      unset_command;
      init_command;
    ]
