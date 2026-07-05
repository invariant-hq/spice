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
module Provider = Spice_provider
module Llm_provider = Spice_llm.Provider
module Model = Spice_provider.Model
module Reasoning_effort = Spice_llm.Request.Options.Reasoning_effort
module Model_choice = Spice_host.Models.Model_choice
module Models = Spice_host.Models
module Reason = Spice_host.Reason
module Account = Spice_host.Account

let status_string = function
  | Model.Stable -> "stable"
  | Model.Preview -> "preview"
  | Model.Deprecated -> "deprecated"
  | Model.Unavailable reason -> "unavailable:" ^ reason

let api_string model = Spice_llm.Model.Api.id (Model.api model)
let date_string date = Model.Date.to_string date
let selector_string selector = selector

let json_strings values =
  values |> List.map (fun value -> Jsont.Json.string value) |> json_list

let json_null_or_float = function
  | None -> json_null
  | Some value -> Jsont.Json.number value

let json_reasoning_effort = function
  | None -> json_null
  | Some effort -> Jsont.Json.string (Reasoning_effort.to_string effort)

let rate_json rate =
  json_obj
    [
      ("input_per_million", json_null_or_float rate.Model.input_per_million);
      ( "cached_input_per_million",
        json_null_or_float rate.Model.cached_input_per_million );
      ("output_per_million", json_null_or_float rate.Model.output_per_million);
      ( "cache_write_5m_per_million",
        json_null_or_float rate.Model.cache_write_5m_per_million );
      ( "cache_write_1h_per_million",
        json_null_or_float rate.Model.cache_write_1h_per_million );
    ]

let pricing_json = function
  | None -> json_null
  | Some pricing ->
      json_obj
        [
          ("default", rate_json pricing.Model.default);
          ( "context_over",
            pricing.Model.context_over
            |> List.map (fun (threshold, rate) ->
                json_obj
                  [
                    ("context_over", Jsont.Json.int threshold);
                    ("rate", rate_json rate);
                  ])
            |> json_list );
        ]

(* Fit verdicts exist only for models whose provider owns local weights; the
   provider package is the single fit-policy entry point.

   This is a CLI-owned display enrichment, not part of the provider-neutral
   [Model_artifact] seam, and it deliberately reaches into [Spice_llm_local.Fit]
   for that one provider. A memory-budget verdict computed against this machine's
   [SPICE_LOCAL_MEMORY_BUDGET] is meaningful only for local weights; folding it
   into the neutral host vocabulary would make every other provider answer
   [null] and leak local-weights specificity into the seam whose purpose is to
   erase it. Unlike download dispatch (which is host-neutralized), this coupling
   stays here by design. *)
let model_fit model =
  if Llm_provider.equal (Model.provider model) Spice_llm_local.provider then
    Spice_llm_local.Fit.find (Model.id model)
  else None

let fit_display model =
  Option.fold ~none:"-" ~some:Spice_llm_local.Fit.to_string (model_fit model)

let fit_json model =
  match model_fit model with
  | None -> json_null
  | Some fit ->
      let verdict, max_context =
        match fit.Spice_llm_local.Fit.verdict with
        | Spice_modelfit.Verdict.Fits -> ("fits", None)
        | Spice_modelfit.Verdict.Tight { max_context } ->
            ("tight", Some max_context)
        | Spice_modelfit.Verdict.Wont_run -> ("wont_run", None)
      in
      json_obj
        [
          ("verdict", Jsont.Json.string verdict);
          ("max_context", json_null_or_int max_context);
          ("need_bytes", Jsont.Json.int fit.Spice_llm_local.Fit.need_bytes);
          ("budget_bytes", Jsont.Json.int fit.Spice_llm_local.Fit.budget_bytes);
        ]

let cost_input model =
  Option.bind (Model.pricing model) (fun pricing ->
      pricing.Model.default.Model.input_per_million)

let cost_output model =
  Option.bind (Model.pricing model) (fun pricing ->
      pricing.Model.default.Model.output_per_million)

let cost_display input output =
  match (input, output) with
  | None, None -> "-"
  | input, output ->
      let fmt = function
        | None -> "?"
        | Some value -> Printf.sprintf "%g" value
      in
      fmt input ^ "/" ^ fmt output

let model_fields ~provider_default model =
  [
    ("provider", Jsont.Json.string (Llm_provider.id (Model.provider model)));
    ("id", Jsont.Json.string (Model.id model));
    ("api", Jsont.Json.string (api_string model));
    ("selector", Jsont.Json.string (selector_string (Model.selector model)));
    ("display_name", json_null_or_string (Model.display_name model));
    ("family", json_null_or_string (Model.family model));
    ( "released_on",
      json_null_or_string (Option.map date_string (Model.released_on model)) );
    ("status", Jsont.Json.string (status_string (Model.status model)));
    ("visible", Jsont.Json.bool (Model.visible model));
    ("selectable", Jsont.Json.bool (Model.selectable model));
    ("provider_default", Jsont.Json.bool provider_default);
    ("context_window", json_null_or_int (Model.context_window model));
    ("max_output_tokens", json_null_or_int (Model.max_output_tokens model));
    ("default_reasoning", json_reasoning_effort (Model.default_reasoning model));
    ( "supported_reasoning",
      Model.supported_reasoning model
      |> List.map Reasoning_effort.to_string
      |> json_strings );
    ( "input_modalities",
      Model.input_modalities model
      |> List.map Model.Modality.to_string
      |> json_strings );
    ( "output_modalities",
      Model.output_modalities model
      |> List.map Model.Modality.to_string
      |> json_strings );
    ( "capabilities",
      Model.capabilities model
      |> List.map Model.Capability.to_string
      |> json_strings );
    ("pricing", pricing_json (Model.pricing model));
    ("fit", fit_json model);
  ]

let model_json ~provider_default model =
  json_obj (model_fields ~provider_default model)

let host_error_message error =
  Spice_diagnostic.to_string (Spice_host.Host.Error.diagnostic error)

let is_provider_default catalog model =
  Option.bind
    (Provider.Catalog.provider catalog (Model.provider model))
    Provider.default_model
  |> Option.map (fun default ->
      Spice_llm.Model.equal (Model.llm model) (Model.llm default))
  |> Option.value ~default:false

let print_models catalog models =
  let rows =
    List.map
      (fun model ->
        let selector = selector_string (Model.selector model) in
        let selector =
          if is_provider_default catalog model then selector ^ " *"
          else selector
        in
        [
          selector;
          status_string (Model.status model);
          Option.value
            (Option.map string_of_int (Model.context_window model))
            ~default:"-";
          cost_display (cost_input model) (cost_output model);
          fit_display model;
        ])
      models
  in
  print_table
    ~header:[ "MODEL"; "STATUS"; "CONTEXT"; "COST $/MTOK"; "FIT" ]
    rows;
  if List.exists (is_provider_default catalog) models then
    stdout_printf "* provider default\n"

let print_model_detail catalog model =
  let field label value = stdout_printf "%-20s %s\n" label value in
  let join to_string values =
    match values with
    | [] -> "-"
    | values -> values |> List.map to_string |> String.concat ", "
  in
  let opt to_string = Option.fold ~none:"-" ~some:to_string in
  let selector = selector_string (Model.selector model) in
  field "selector"
    (if is_provider_default catalog model then selector ^ " *" else selector);
  field "display_name" (opt Fun.id (Model.display_name model));
  field "api" (api_string model);
  field "family" (opt Fun.id (Model.family model));
  field "released_on" (opt date_string (Model.released_on model));
  field "status" (status_string (Model.status model));
  field "context_window" (opt string_of_int (Model.context_window model));
  field "max_output_tokens" (opt string_of_int (Model.max_output_tokens model));
  field "default_reasoning"
    (opt Reasoning_effort.to_string (Model.default_reasoning model));
  field "supported_reasoning"
    (join Reasoning_effort.to_string (Model.supported_reasoning model));
  field "input_modalities"
    (join Model.Modality.to_string (Model.input_modalities model));
  field "output_modalities"
    (join Model.Modality.to_string (Model.output_modalities model));
  field "capabilities"
    (join Model.Capability.to_string (Model.capabilities model));
  field "cost" (cost_display (cost_input model) (cost_output model));
  field "fit" (fit_display model)

let list json raw_provider all =
  with_host @@ fun ~stdenv:_ host ->
  let catalog = Spice_host.Host.catalog host in
  match raw_provider with
  | Some provider
    when Option.is_none (Provider.Catalog.provider catalog provider) ->
      Usage_error
        (host_error_message
           (Spice_host.Host.Error.Unknown_provider
              {
                provider;
                field = None;
                known = Spice_host.Host.provider_ids host;
              }))
  | provider ->
      let models =
        match provider with
        | None -> Provider.Catalog.models ~include_hidden:all catalog
        | Some provider -> (
            match
              Provider.Catalog.models_for ~include_hidden:all catalog provider
            with
            | Ok models -> models
            | Error _ -> [])
      in
      if json then
        stdout_printf "%s\n"
          (json_string
             (json_obj
                [
                  ("schema_version", Jsont.Json.int 1);
                  ("type", Jsont.Json.string "models");
                  ( "models",
                    models
                    |> List.map (fun model ->
                        model_json
                          ~provider_default:(is_provider_default catalog model)
                          model)
                    |> json_list );
                ]))
      else print_models catalog models;
      Success

let show json raw =
  with_host @@ fun ~stdenv:_ host ->
  let catalog = Spice_host.Host.catalog host in
  match Models.resolve catalog raw with
  | Error error -> Usage_error (host_error_message error)
  | Ok choice ->
      let model = Model_choice.model choice in
      if json then
        stdout_printf "%s\n"
          (json_string
             (json_obj
                [
                  ("schema_version", Jsont.Json.int 1);
                  ("type", Jsont.Json.string "model");
                  ( "model",
                    model_json
                      ~provider_default:(is_provider_default catalog model)
                      model );
                ]))
      else print_model_detail catalog model;
      Success

(* Current-model rendering: each role reports its model, its reason
   (config origin or fallback reason), passive credential readiness, and any
   active base URL override. *)

let config_source_label source =
  match source with
  | Config.Source.User _ -> "user config"
  | Config.Source.Project _ -> "project config"
  | Config.Source.Project_local _ -> "project-local config"
  | Config.Source.Extra_file _ -> "extra config file"
  | Config.Source.Env { name } -> "env " ^ name
  | Config.Source.Override -> "override"
  | Config.Source.Default _ -> "default"

let derived_reason_label = function
  | "provider_default" -> "provider default"
  | "first_selectable" -> "first selectable"
  | "small_heuristic" -> "small heuristic"
  | "main_fallback" -> "main model"
  | label -> label

let reason_label reason =
  match Reason.source reason with
  | Reason.Config source -> config_source_label source
  | Reason.Explicit label -> label
  | Reason.Derived label -> derived_reason_label label

let credentials_text account =
  let label = account_status_string account in
  match Spice_account.source account with
  | None -> label
  | Some source -> (
      match Spice_account.Credential.Source.name source with
      | Some name ->
          Printf.sprintf "%s (%s %s)" label (account_source_string source) name
      | None -> Printf.sprintf "%s (%s)" label (account_source_string source))

let reason_fields reason =
  match Reason.config_origin reason with
  | Some origin -> [ ("origin", json_encode Config.Origin.jsont origin) ]
  | None -> [ ("fallback_reason", Jsont.Json.string (Reason.to_string reason)) ]

let credentials_field account =
  let source = Spice_account.source account in
  [
    ( "credentials",
      json_obj
        [
          ("status", Jsont.Json.string (account_status_string account));
          ( "source",
            json_null_or_string (Option.map account_source_string source) );
          ( "source_name",
            json_null_or_string
              (Option.bind source Spice_account.Credential.Source.name) );
        ] );
  ]

let base_url_field host model =
  Config.Models.provider_base_url
    (Config.models (Spice_host.Host.config host))
    ~provider:(Model.provider model)
  |> Option.map (fun base_url -> ("base_url", Jsont.Json.string base_url))
  |> Option.to_list

let role_json host catalog account choice =
  let model = Model_choice.model choice in
  json_obj
    (model_fields ~provider_default:(is_provider_default catalog model) model
    @ reason_fields (Model_choice.reason choice)
    @ credentials_field account @ base_url_field host model)

let role_account account choice =
  Account.status account (Model.provider (Model_choice.model choice))

let current json =
  with_host @@ fun ~stdenv host ->
  let catalog = Spice_host.Host.catalog host in
  let result =
    let* main, small =
      match
        ( Spice_host.Models.choose host Model_choice.Main,
          Spice_host.Models.choose host Model_choice.Small )
      with
      | Error error, _ | _, Error error ->
          Error (Runtime_error (host_error_message error))
      | Ok main, Ok small -> Ok (main, small)
    in
    let* account =
      Account.load ~stdenv host
      |> Result.map_error (fun e -> Runtime_error (Account.Error.message e))
    in
    let* main_account =
      role_account account main
      |> Result.map_error (fun e -> Runtime_error (Account.Error.message e))
    in
    let* small_account =
      role_account account small
      |> Result.map_error (fun e -> Runtime_error (Account.Error.message e))
    in
    (if json then
       stdout_printf "%s\n"
         (json_string
            (json_obj
               [
                 ("schema_version", Jsont.Json.int 1);
                 ("type", Jsont.Json.string "models_current");
                 ("model", role_json host catalog main_account main);
                 ("small_model", role_json host catalog small_account small);
               ]))
     else
       let role_row role choice account =
         let model = Model_choice.model choice in
         [
           role;
           selector_string (Model.selector model);
           reason_label (Model_choice.reason choice);
           credentials_text account;
         ]
       in
       print_table
         ~header:[ "ROLE"; "MODEL"; "SOURCE"; "CREDENTIALS" ]
         [
           role_row "model" main main_account;
           role_row "small" small small_account;
         ]);
    Ok Success
  in
  match result with Ok status | Error status -> status

(* Download: fetch a local-weights model's artifact ahead of first use. The
   provider packages own the download, verification, and the memory guard;
   the CLI resolves the selector, renders progress, and carries the [--force]
   override. *)

let pp_gib ppf bytes =
  Format.fprintf ppf "%.1f GiB"
    (Int64.to_float bytes /. (1024. *. 1024. *. 1024.))

let download_progress_line ~label ~received ~total =
  match total with
  | Some total when Int64.compare total 0L > 0 ->
      Format.asprintf "\rdownloading %s: %a / %a" label pp_gib received pp_gib
        total
  | Some _ | None ->
      Format.asprintf "\rdownloading %s: %a" label pp_gib received

let download force raw =
  with_host @@ fun ~stdenv host ->
  let catalog = Spice_host.Host.catalog host in
  match Models.resolve catalog raw with
  | Error error -> Usage_error (host_error_message error)
  | Ok choice -> (
      let model = Model_choice.model choice in
      let provider = Llm_provider.id (Model.provider model) in
      let observe (progress : Spice_protocol.Model_artifact.progress) =
        let label = progress.Spice_protocol.Model_artifact.label in
        match progress.Spice_protocol.Model_artifact.phase with
        | Spice_protocol.Model_artifact.Checking ->
            stderr_printf "fetching %s%s\n%!" label
              (match progress.Spice_protocol.Model_artifact.total with
              | Some total -> Format.asprintf " (%a)" pp_gib total
              | None -> "")
        | Spice_protocol.Model_artifact.Downloading ->
            stderr_printf "%s%!"
              (download_progress_line ~label
                 ~received:progress.Spice_protocol.Model_artifact.received
                 ~total:progress.Spice_protocol.Model_artifact.total)
        | Spice_protocol.Model_artifact.Verifying ->
            stderr_printf "\nverifying %s\n%!" label
        | Spice_protocol.Model_artifact.Ready ->
            stderr_printf "installed %s\n%!"
              progress.Spice_protocol.Model_artifact.path
      in
      let outcome =
        Eio.Switch.run @@ fun sw ->
        Spice_host.download_model_artifact host ~sw ~stdenv ~observe ~force
          model
      in
      match outcome with
      | None ->
          Usage_error
            (Printf.sprintf
               "models download fetches local weights; %S is a hosted provider"
               provider)
      | Some (Spice_protocol.Model_artifact.Already_installed path) ->
          stdout_printf "already installed: %s\n" path;
          Success
      | Some Spice_protocol.Model_artifact.Not_downloadable ->
          Usage_error
            "explicit model paths are local files and are not downloadable"
      | Some Spice_protocol.Model_artifact.Downloaded -> Success
      | Some (Spice_protocol.Model_artifact.Refused { message; force_hint }) ->
          let hint =
            if force_hint then " (--force overrides the guard)" else ""
          in
          Runtime_error (message ^ hint))

(* [select] is sugar over [spice config set]: same validation, same write
   path, by construction. *)
let select target small raw =
  let key =
    if small then Config.Field.Any Config.Field.small_model
    else Config.Field.Any Config.Field.model
  in
  Cli_config.set target key raw

let list_term =
  let json =
    Cli_arg.json_flag ()
  in
  let provider =
    CArg.(
      value
      & opt (some Cli_arg.provider) None
      & info [ "provider" ] ~docv:"PROVIDER" ~doc:"Only list one provider.")
  in
  let all =
    CArg.(
      value & flag
      & info [ "all" ] ~doc:"Include hidden and unavailable models.")
  in
  CTerm.(const list $ json $ provider $ all)

let show_command =
  let json =
    Cli_arg.json_flag ()
  in
  let model =
    CArg.(required & pos 0 (some string) None & info [] ~docv:"MODEL")
  in
  CCmd.v
    (CCmd.info "show" ~doc:"Show one model as $(b,provider/model)." ~exits)
    (exit_term CTerm.(const show $ json $ model))

let current_command =
  let json =
    Cli_arg.json_flag ()
  in
  CCmd.v
    (CCmd.info "current"
       ~doc:
         "Show the effective main and small models and why each was selected."
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Reports the resolved main and small models, the source of each \
              selection, and passive credential readiness. Clear configured \
              selections with $(b,spice config unset model) and $(b,spice \
              config unset small_model).";
         ]
       ~exits)
    (exit_term CTerm.(const current $ json))

let download_command =
  let model =
    CArg.(required & pos 0 (some string) None & info [] ~docv:"MODEL")
  in
  let force =
    CArg.(
      value & flag
      & info [ "force" ]
          ~doc:
            "Download even when the memory guard says this machine cannot run \
             the model.")
  in
  CCmd.v
    (CCmd.info "download"
       ~doc:"Download a local model's weights ahead of first use."
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Fetches the model artifact for a local-weights provider, \
              verifies its size and checksum, and installs it into the model \
              directory. Models the machine cannot run are refused before any \
              bytes move; $(b,--force) overrides the guard. Hosted provider \
              models are not downloadable.";
         ]
       ~exits)
    (exit_term CTerm.(const download $ force $ model))

let select_command =
  let model =
    CArg.(required & pos 0 (some string) None & info [] ~docv:"MODEL")
  in
  let small =
    CArg.(
      value & flag
      & info [ "small" ] ~doc:"Write the auxiliary small-model config key.")
  in
  CCmd.v
    (CCmd.info "select" ~doc:"Write the selected model to config."
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Writes the canonical selector to the chosen config target. Undo \
              with $(b,spice config unset model) or $(b,spice config unset \
              small_model).";
         ]
       ~exits)
    (exit_term CTerm.(const select $ Cli_arg.config_target $ small $ model))

let group =
  CCmd.group
    (CCmd.info "models" ~doc:"Inspect and select known models."
       ~docs:s_config_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Lists the model catalog with availability, context windows, and \
              pricing; $(b,*) marks each provider's default model. \
              $(b,current) explains which models a run would use and why; \
              $(b,select) writes a choice to config.";
           `S CManpage.s_examples;
           `Pre "  spice models --provider anthropic";
           `Pre "  spice models select anthropic/claude-sonnet-4-6";
         ]
       ~exits)
    ~default:(exit_term list_term)
    [ show_command; current_command; select_command; download_command ]
