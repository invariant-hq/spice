(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
module Config = Spice_host.Config
module Skills = Spice_host.Skills
module Skill = Skills.Skill

let json_string json =
  match Jsont_bytesrw.encode_string ~format:Jsont.Minify Jsont.json json with
  | Ok text -> text
  | Error message -> failwith message

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let with_skills f =
  Eio_main.run @@ fun stdenv ->
  let process_env = Spice_host.Env.current () in
  match Config.load ~stdenv ~process_env () with
  | Error error -> Runtime_error (Config.Error.message error)
  | Ok config ->
      let skills =
        Skills.load ~stdenv ~builtins:Spice_prompts.Skills.all config
      in
      f config skills

(* Text rendering *)

let bool_text value = if value then "true" else "false"

let print_policy config skills =
  let skills_config = Config.skills config in
  stdout_printf "Skills: %s\n"
    (if Skills.enabled skills then "enabled" else "disabled (skills.enabled)");
  if Skills.enabled skills then begin
    stdout_printf "  builtin: %s  project: %s  compat: %s\n"
      (bool_text (Config.Skills.builtin skills_config))
      (bool_text (Config.Skills.project skills_config))
      (bool_text (Config.Skills.compat skills_config));
    stdout_printf "  catalog budget: %d bytes (%d used)\n"
      (Config.Skills.catalog_max_bytes skills_config)
      (Skills.Catalog.bytes (Skills.catalog skills))
  end

let split_status skills =
  List.partition
    (fun skill ->
      match Skill.status skill with Skill.Active _ -> true | _ -> false)
    (Skills.skills skills)

let print_active skills =
  match skills with
  | [] -> stdout_printf "\nActive skills: (none)\n"
  | skills ->
      stdout_printf "\nActive skills:\n";
      List.iteri
        (fun index skill ->
          match Skill.status skill with
          | Skill.Active content ->
              stdout_printf "  [%d] %s  %s  %s\n" (index + 1)
                (Skill.Name.to_string (Skill.name skill))
                (Skill.kind_string (Skill.kind skill))
                (Skill.origin skill);
              stdout_printf "      %s\n" content.Skill.description
          | _ -> ())
        skills

let print_inactive skills =
  match skills with
  | [] -> ()
  | skills ->
      stdout_printf "\nInactive skills:\n";
      List.iter
        (fun skill ->
          let reason =
            match Skill.status skill with
            | Skill.Shadowed { by } -> "shadowed by " ^ by
            | status -> (
                match Skill.reason_string status with
                | Some reason -> Skill.state_string status ^ " " ^ reason
                | None -> Skill.state_string status)
          in
          stdout_printf "  %s %s (%s)\n"
            (Skill.Name.to_string (Skill.name skill))
            reason (Skill.origin skill))
        skills

let print_warnings warnings =
  stdout_printf "\nWarnings:\n";
  match warnings with
  | [] -> stdout_printf "  (none)\n"
  | warnings ->
      List.iter (fun warning -> stdout_printf "  %s\n" warning) warnings

let list_json config skills =
  let skills_config = Config.skills config in
  json_obj
    [
      ("schema_version", Jsont.Json.int 1);
      ("type", Jsont.Json.string "skills_list");
      ( "config",
        json_obj
          [
            ("enabled", Jsont.Json.bool (Config.Skills.enabled skills_config));
            ("builtin", Jsont.Json.bool (Config.Skills.builtin skills_config));
            ("project", Jsont.Json.bool (Config.Skills.project skills_config));
            ("compat", Jsont.Json.bool (Config.Skills.compat skills_config));
            ( "paths",
              Jsont.Json.list
                (List.map
                   (fun value -> Jsont.Json.string value)
                   (Config.Skills.paths skills_config)) );
            ( "catalog_max_bytes",
              Jsont.Json.int (Config.Skills.catalog_max_bytes skills_config) );
          ] );
      ("catalog", Skills.Catalog.to_json (Skills.catalog skills));
      ("skills", Jsont.Json.list (List.map Skill.to_json (Skills.skills skills)));
      ( "warnings",
        Jsont.Json.list
          (List.map
             (fun value -> Jsont.Json.string value)
             (Skills.warnings skills)) );
    ]

let list json =
  with_skills @@ fun config skills ->
  if json then stdout_printf "%s\n" (json_string (list_json config skills))
  else begin
    print_policy config skills;
    if Skills.enabled skills then begin
      let active, inactive = split_status skills in
      print_active active;
      print_inactive inactive;
      print_warnings (Skills.warnings skills)
    end
  end;
  Success

let show json name =
  with_skills @@ fun _config skills ->
  match Skill.Name.of_string name with
  | Error message -> Runtime_error message
  | Ok skill_name -> (
      match Skills.find_active skills skill_name with
      | None ->
          let known =
            Skills.skills skills
            |> List.filter_map (fun skill ->
                match Skill.status skill with
                | Skill.Active _ ->
                    Some (Skill.Name.to_string (Skill.name skill))
                | _ -> None)
          in
          Runtime_error
            (Printf.sprintf "unknown skill %S; available skills: %s" name
               (match known with
               | [] -> "(none)"
               | known -> String.concat ", " known))
      | Some (skill, content) ->
          if json then
            stdout_printf "%s\n"
              (json_string
                 (json_obj
                    [
                      ("schema_version", Jsont.Json.int 1);
                      ("type", Jsont.Json.string "skills_show");
                      ("skill", Skill.to_json skill);
                      ("text", Jsont.Json.string content.Skill.text);
                    ]))
          else begin
            stdout_printf "name: %s\n" (Skill.Name.to_string (Skill.name skill));
            (match content.Skill.display_name with
            | Some display -> stdout_printf "display name: %s\n" display
            | None -> ());
            stdout_printf "kind: %s\n" (Skill.kind_string (Skill.kind skill));
            stdout_printf "origin: %s\n" (Skill.origin skill);
            stdout_printf "digest: %s\n" content.Skill.digest;
            stdout_printf "bytes: %d\n" content.Skill.bytes;
            (match content.Skill.ignored_keys with
            | [] -> ()
            | keys ->
                stdout_printf "ignored frontmatter keys: %s\n"
                  (String.concat ", " keys));
            (match content.Skill.resources with
            | [] -> ()
            | resources ->
                stdout_printf "resources:\n";
                List.iter
                  (fun resource -> stdout_printf "  %s\n" resource)
                  resources);
            stdout_printf "\n%s\n" content.Skill.text
          end;
          Success)

let json_flag = Cli_arg.json_flag ()

let name_arg =
  CArg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"NAME" ~doc:"Skill name.")

let list_command =
  CCmd.v
    (CCmd.info "list" ~doc:"List discovered skills and their states." ~exits)
    (exit_term CTerm.(const list $ json_flag))

let show_command =
  CCmd.v
    (CCmd.info "show" ~doc:"Show one active skill." ~exits)
    (exit_term CTerm.(const show $ json_flag $ name_arg))

let group =
  CCmd.group
    (CCmd.info "skills" ~doc:"Inspect discovered skills."
       ~docs:s_diagnostic_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Skills are named, reusable guidance loaded into runs on demand. \
              This group shows what was discovered, what is active, and how \
              much of the catalog budget the descriptions consume.";
         ]
       ~exits)
    [ list_command; show_command ]
