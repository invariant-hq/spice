(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let version () =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some v -> "v" ^ Build_info.V1.Version.to_string v

(* The curated config inventory: the spec's seven family groups and 24 rows
   (03-ia-screens-overlays.md §Settings), each label bound to its real
   {!Spice_host.Config.Field} and how it edits. Fields outside these families —
   the [run.*], [shell], [sandbox.writable_roots]/[network]/[toolchain_caches],
   the byte-budget and path-list fields, [tools.editor], and
   [ocaml.merlin_program] — are not surfaced here; [skills.disabled] is edited
   through the skills tab's toggle instead. *)
type kind = Managed_kind | Bool_kind | Enum_kind | Text_kind

let config_groups_spec =
  let open Spice_host.Config.Field in
  [
    ( "Model & reasoning",
      [
        ("Model", Any model, Managed_kind);
        ("Small model", Any small_model, Text_kind);
        ("Reasoning", Any reasoning, Enum_kind);
        ("Thinking summaries", Any tui_thinking, Bool_kind);
      ] );
    ( "Permissions & sandbox",
      [
        ("Permission mode", Any permission_mode, Enum_kind);
        ("Unattended permission", Any permission_unattended, Enum_kind);
        ("Sandbox mode", Any sandbox_mode, Enum_kind);
        ("Sandbox required", Any sandbox_require, Enum_kind);
      ] );
    ("Context", [ ("Auto compact", Any compaction_auto, Bool_kind) ]);
    ( "Instructions",
      [
        ("Global instructions", Any instructions_global, Bool_kind);
        ("Project instructions", Any instructions_project, Bool_kind);
        ("Claude.md instructions", Any instructions_claude_md, Bool_kind);
      ] );
    ( "Notices",
      [
        ("Filesystem notices", Any notices_fswatch, Bool_kind);
        ("Code review notices", Any notices_cr_comments, Bool_kind);
        ("Dune diagnostic notices", Any notices_dune_diagnostics, Bool_kind);
        ("Dune build notices", Any notices_dune_build, Bool_kind);
      ] );
    ( "Skills",
      [
        ("Skills", Any skills_enabled, Bool_kind);
        ("Builtin skills", Any skills_builtin, Bool_kind);
        ("Project skills", Any skills_project, Bool_kind);
        ("Compat skills", Any skills_compat, Bool_kind);
      ] );
    ( "Tools & web",
      [
        ("Anchored edits", Any tools_anchored_edits, Bool_kind);
        ("Web tools", Any web_enabled, Bool_kind);
        ("Private network web", Any web_allow_private_network, Bool_kind);
        ("Web search", Any web_search_backend, Enum_kind);
      ] );
  ]

(* The advisory caution after a dangerous value (03-ia §Settings, 06-panels): not
   a confirmation prompt, just a warning suffix. *)
let danger_of name value =
  match (name, value) with
  | "permission.mode", "bypass" -> Some "approvals skipped"
  | "sandbox.mode", "danger-full-access" -> Some "no filesystem confinement"
  | "sandbox.require", "off" -> Some "sandbox not required"
  | _ -> None

let config_row_of config (label, any, kind) =
  let (Spice_host.Config.Field.Any field) = any in
  let name = Spice_host.Config.Field.name field in
  let current = Option.value (Spice_host.Config.get field config) ~default:"" in
  let is_default = Option.is_none (Spice_host.Config.find field config) in
  let value =
    match kind with
    | Managed_kind -> Settings_screen.Config.Managed current
    | Bool_kind -> Settings_screen.Config.Toggle (String.equal current "true")
    | Text_kind -> Settings_screen.Config.Text current
    | Enum_kind ->
        let options =
          Option.value (Spice_host.Config.Field.values field) ~default:[]
        in
        Settings_screen.Config.Enum { current; options }
  in
  {
    Settings_screen.Config.field = name;
    label;
    value;
    is_default;
    danger = danger_of name current;
  }

(* The rule's right label: the config sources that contributed a value, in a
   fixed precedence order, defaults ([preset]) and runtime overrides dropped. *)
let config_sources config =
  let kinds =
    List.filter_map
      (fun (_, origin) ->
        match
          Spice_host.Config.Source.kind_string
            (Spice_host.Config.Origin.source origin)
        with
        | "preset" | "override" -> None
        | k -> Some k)
      (Spice_host.Config.origins config)
  in
  [ "user"; "project"; "project-local"; "extra"; "env" ]
  |> List.filter (fun k -> List.mem k kinds)
  |> String.concat " + "

let config_facts config =
  let groups =
    List.map
      (fun (title, entries) ->
        { Settings_screen.Config.title; rows = List.map (config_row_of config) entries })
      config_groups_spec
  in
  { Settings_screen.Config.groups; sources = config_sources config }

(* Status. *)

let model_label model =
  let llm = Spice_provider.Model.llm model in
  Spice_llm.Provider.id (Spice_llm.Model.provider llm)
  ^ "/" ^ Spice_llm.Model.id llm

let model_status_string = function
  | Spice_provider.Model.Stable -> "stable"
  | Spice_provider.Model.Preview -> "preview"
  | Spice_provider.Model.Deprecated -> "deprecated"
  | Spice_provider.Model.Unavailable reason -> "unavailable: " ^ reason

let resolved_model host =
  match Spice_host.Models.choose host Spice_host.Models.Model_choice.Main with
  | Ok choice -> Some (Spice_host.Models.Model_choice.model choice)
  | Error _ -> None

let account_line ~stdenv host provider =
  match Spice_host.Account.load ~stdenv host with
  | Error _ -> "unavailable"
  | Ok accounts -> (
      match Spice_host.Account.status accounts provider with
      | Error _ -> "unavailable"
      | Ok account -> (
          let id = Spice_llm.Provider.id provider in
          match Spice_account.phase account with
          | `Missing -> "not connected · /login"
          | (`Blocked | `Unchecked | `Ready | `Degraded) as phase ->
              let label = Spice_account.phase_to_string phase in
              let who =
                match Spice_account.profile account with
                | Some p -> (
                    match p.Spice_account.Profile.email with
                    | Some email -> email
                    | None -> id)
                | None -> id
              in
              let base = Printf.sprintf "%s · %s %s" who id label in
              (* A stored-but-rejected credential ([`Blocked]) needs re-auth, so
                 it carries the [/login] pointer the way [`Missing] does
                 (09-auth.md §States). *)
              (match phase with `Blocked -> base ^ " · /login" | _ -> base)))

let session_line = function
  | None -> "none"
  | Some session ->
      let title =
        match Spice_session.Metadata.title (Spice_session.metadata session) with
        | Some t when String.trim t <> "" -> t
        | _ -> "untitled"
      in
      Printf.sprintf "%s · %s" title
        (Spice_session.Id.to_string (Spice_session.id session))

let status_facts ~stdenv host config ~session ~model =
  let model_row =
    match model with
    | Some m ->
        Printf.sprintf "%s · %s" (model_label m)
          (model_status_string (Spice_provider.Model.status m))
    | None -> "unavailable"
  in
  let permission =
    Spice_host.Permission.Preset.to_string
      (Spice_host.Config.Permissions.mode (Spice_host.Config.permissions config))
  in
  let sandbox =
    match Spice_host.Config.Sandbox.mode (Spice_host.Config.sandbox config) with
    | Some m -> Spice_host.Sandbox.Mode.to_string m
    | None -> "off"
  in
  let account =
    match model with
    | Some m -> account_line ~stdenv host (Spice_provider.Model.provider m)
    | None -> "unavailable"
  in
  let path abs = Path_display.home_relative abs in
  let files = Spice_host.Config.files config in
  let fact label value = { Settings_screen.Status.label; value } in
  {
    Settings_screen.Status.session_id =
      Option.map
        (fun s -> Spice_session.Id.to_string (Spice_session.id s))
        session;
    rows =
      [
        fact "version" (version ());
        fact "session" (session_line session);
        fact "cwd" (path (Spice_host.Config.cwd config));
        fact "account" account;
        fact "model" model_row;
        fact "permission" permission;
        fact "sandbox" sandbox;
        fact "trust" "not enforced";
        fact "user config" (path (Spice_host.Config.Config_file.user files));
        fact "project config"
          (path (Spice_host.Config.Config_file.project files));
      ];
  }

(* Usage. *)

let usage_facts ~session ~model =
  match session with
  | None ->
      {
        Settings_screen.Usage.has_turns = false;
        model = "";
        lanes = [];
        cost = "";
        scope = "";
      }
  | Some session ->
      let metrics = Spice_session.Metrics.of_session session in
      let usage = metrics.Spice_session.Metrics.usage in
      let lane label tokens = { Settings_screen.Usage.label; tokens } in
      let lanes =
        [
          lane "input" usage.Spice_llm.Usage.input;
          lane "output" usage.Spice_llm.Usage.output;
          lane "reasoning" usage.Spice_llm.Usage.reasoning;
          lane "cache read" usage.Spice_llm.Usage.cache_read;
          lane "cache write" usage.Spice_llm.Usage.cache_write;
          lane "total" (Spice_llm.Usage.sum_lanes usage);
        ]
      in
      let cost =
        match model with
        | Some m -> (
            match Spice_provider.Model.cost m usage with
            | Some c -> Printf.sprintf "$%.4f" c
            | None -> "cost unavailable")
        | None -> "cost unavailable"
      in
      {
        Settings_screen.Usage.has_turns = metrics.Spice_session.Metrics.turns > 0;
        model =
          (match model with Some m -> model_label m | None -> "unavailable");
        lanes;
        cost;
        scope = "this session — plan quotas and all-time totals are not tracked";
      }

(* Skills. *)

let skill_row_of skill =
  let status = Spice_host.Skills.Skill.status skill in
  let description =
    match status with
    | Spice_host.Skills.Skill.Active content ->
        Some content.Spice_host.Skills.Skill.description
    | _ -> Spice_host.Skills.Skill.reason_string status
  in
  {
    Settings_screen.Skills.name =
      Spice_host.Skills.Skill.Name.to_string (Spice_host.Skills.Skill.name skill);
    state = Spice_host.Skills.Skill.state_string status;
    source =
      Spice_host.Skills.Skill.kind_string (Spice_host.Skills.Skill.kind skill);
    cost = Option.value (Spice_host.Skills.Skill.context_cost skill) ~default:0;
    enabled =
      (match status with Spice_host.Skills.Skill.Active _ -> true | _ -> false);
    description;
  }

let skills_facts ~stdenv config =
  let snapshot =
    Spice_host.Skills.load ~stdenv ~builtins:Spice_prompts.Skills.all config
  in
  let skills = Spice_host.Skills.skills snapshot in
  let catalog = Spice_host.Skills.catalog snapshot in
  let active_cost =
    List.fold_left
      (fun acc s ->
        match Spice_host.Skills.Skill.status s with
        | Spice_host.Skills.Skill.Active _ ->
            acc
            + Option.value (Spice_host.Skills.Skill.context_cost s) ~default:0
        | _ -> acc)
      0 skills
  in
  {
    Settings_screen.Skills.rows = List.map skill_row_of skills;
    budget = Spice_host.Skills.Catalog.context_cost catalog + active_cost;
    available = Spice_host.Skills.enabled snapshot;
  }

let assemble ~stdenv ~host ~session =
  let config = Spice_host.Host.config host in
  let model = resolved_model host in
  {
    Settings_screen.config = config_facts config;
    status = status_facts ~stdenv host config ~session ~model;
    usage = usage_facts ~session ~model;
    skills = skills_facts ~stdenv config;
  }
