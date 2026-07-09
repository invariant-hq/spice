(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term

let user_error_message message =
  match String.split_first ~sep:":" message with
  | None -> message
  | Some (_, rest) -> String.trim rest

let provider =
  let parse raw =
    match Spice_llm.Provider.make raw with
    | provider -> Ok provider
    | exception Invalid_argument message ->
        let message = user_error_message message in
        Error (`Msg ("invalid provider id \"" ^ raw ^ "\": " ^ message))
  in
  CArg.conv (parse, Spice_llm.Provider.pp)

let credential_name =
  let parse raw =
    match Spice_account.Credential.Name.make raw with
    | name -> Ok name
    | exception Invalid_argument message ->
        let message = user_error_message message in
        Error (`Msg ("invalid credential name \"" ^ raw ^ "\": " ^ message))
  in
  CArg.conv (parse, Spice_account.Credential.Name.pp)

let session_id =
  let parse raw =
    match Spice_session.Id.of_string raw with
    | id -> Ok id
    | exception Invalid_argument message ->
        let message = user_error_message message in
        Error (`Msg ("invalid session id \"" ^ raw ^ "\": " ^ message))
  in
  CArg.conv (parse, Spice_session.Id.pp)

let session_permission_id =
  let parse raw =
    match Spice_session.Permission.Id.of_string raw with
    | id -> Ok id
    | exception Invalid_argument message ->
        let message = user_error_message message in
        Error (`Msg ("invalid permission id \"" ^ raw ^ "\": " ^ message))
  in
  CArg.conv (parse, Spice_session.Permission.Id.pp)

let session_tool_claim_id =
  let parse raw =
    match Spice_session.Tool_claim.Id.of_string raw with
    | id -> Ok id
    | exception Invalid_argument message ->
        let message = user_error_message message in
        Error (`Msg ("invalid tool claim id \"" ^ raw ^ "\": " ^ message))
  in
  CArg.conv (parse, Spice_session.Tool_claim.Id.pp)

let config_key =
  let parse raw =
    match Spice_host.Config.Field.of_string raw with
    | Ok key -> Ok key
    | Error error ->
        Error
          (`Msg
             (Spice_diagnostic.to_string
                (Spice_host.Config.Error.diagnostic error)))
  in
  let print ppf (Spice_host.Config.Field.Any key) =
    Format.pp_print_string ppf (Spice_host.Config.Field.name key)
  in
  CArg.conv (parse, print)

let config_target =
  let module Config_file = Spice_host.Config.Config_file in
  let target user project project_local =
    match (user, project, project_local) with
    | true, false, false | false, false, false -> `Ok Config_file.User
    | false, true, false -> `Ok Config_file.Project
    | false, false, true -> `Ok Config_file.Project_local
    | _ -> `Error (false, "choose only one config target")
  in
  CTerm.(
    ret
      (const target
      $ CArg.(value & flag & info [ "user" ] ~doc:"Use user config (default).")
      $ CArg.(
          value & flag & info [ "project" ] ~doc:"Use shared project config.")
      $ CArg.(
          value & flag
          & info [ "project-local" ] ~doc:"Use gitignored project-local config.")
      ))

let instruction_overrides =
  let module Patch = Spice_host.Config.Patch in
  let module Field = Spice_host.Config.Field in
  let set_bool key value layer =
    match Patch.set key (Some (string_of_bool value)) layer with
    | Ok layer -> layer
    | Error _ -> assert false
  in
  let overrides no_instructions project_instructions no_project_instructions =
    if project_instructions && (no_project_instructions || no_instructions) then
      `Error
        ( false,
          "--project-instructions cannot be combined with an \
           instruction-disabling flag" )
    else
      let layer = Patch.empty in
      let layer =
        if no_instructions then set_bool Field.instructions_global false layer
        else layer
      in
      let layer =
        if no_instructions || no_project_instructions then
          set_bool Field.instructions_project false layer
        else if project_instructions then
          set_bool Field.instructions_project true layer
        else layer
      in
      `Ok (if Patch.is_empty layer then [] else [ layer ])
  in
  CTerm.(
    ret
      (const overrides
      $ CArg.(
          value & flag
          & info [ "no-instructions" ] ~docs:Cli_common.s_context_options
              ~doc:"Disable global and project instruction files for this run.")
      $ CArg.(
          value & flag
          & info [ "project-instructions" ] ~docs:Cli_common.s_context_options
              ~doc:
                "Enable project instruction files for this run, overriding \
                 config.")
      $ CArg.(
          value & flag
          & info
              [ "no-project-instructions" ]
              ~docs:Cli_common.s_context_options
              ~doc:"Disable project instruction files for this run.")))

let skills_overrides =
  let module Patch = Spice_host.Config.Patch in
  let module Field = Spice_host.Config.Field in
  let overrides no_skills =
    if not no_skills then []
    else
      match Patch.set Field.skills_enabled (Some "false") Patch.empty with
      | Ok layer -> [ layer ]
      | Error _ -> assert false
  in
  CTerm.(
    const overrides
    $ CArg.(
        value & flag
        & info [ "no-skills" ] ~docs:Cli_common.s_context_options
            ~doc:"Disable skill discovery and the skill tool for this run."))

let run_overrides =
  CTerm.(
    const (fun instructions skills -> instructions @ skills)
    $ instruction_overrides $ skills_overrides)

let config_source =
  let module Config_file = Spice_host.Config.Config_file in
  let source user project project_local =
    match (user, project, project_local) with
    | false, false, false -> `Ok None
    | true, false, false -> `Ok (Some Config_file.User)
    | false, true, false -> `Ok (Some Config_file.Project)
    | false, false, true -> `Ok (Some Config_file.Project_local)
    | _ -> `Error (false, "choose only one config source")
  in
  CTerm.(
    ret
      (const source
      $ CArg.(value & flag & info [ "user" ] ~doc:"Read user config.")
      $ CArg.(
          value & flag & info [ "project" ] ~doc:"Read shared project config.")
      $ CArg.(
          value & flag
          & info [ "project-local" ]
              ~doc:"Read gitignored project-local config.")))

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
  CArg.(
    value
    & opt (conv (parse, Spice_protocol.Mode.pp)) Spice_protocol.Mode.default
    & info [ "mode" ] ~docv:"MODE" ~doc:"Workflow mode: build, plan, or review.")

(* Common leaf arguments shared across commands. Each takes an optional [doc] so
   a command keeps its own wording while the flag or positional's name, value,
   and shape live in one place. *)

let json_flag ?(doc = "Print machine-readable JSON.") () =
  CArg.(value & flag & info [ "json" ] ~doc)

let cwd ?(short = false) ?(doc = "Working directory override.") () =
  let names = if short then [ "C"; "cwd" ] else [ "cwd" ] in
  CArg.(value & opt (some string) None & info names ~docv:"DIR" ~doc)

let model_opt ?(doc = "Provider/model selector, as $(b,provider/model).") () =
  CArg.(value & opt (some string) None & info [ "model" ] ~docv:"MODEL" ~doc)

let last_flag ?(doc = "Target the newest session in this cwd.") () =
  CArg.(value & flag & info [ "last" ] ~doc)

let session_pos ?(doc = "Session id or unique prefix.") () =
  CArg.(value & pos 0 (some session_id) None & info [] ~docv:"SESSION" ~doc)
