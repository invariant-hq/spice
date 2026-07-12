(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* spice permission: durable permission rule inspection and removal.

   The list view renders the same rule table the run policy and blocked-output
   provenance project from (see [Cli_common.permission_args]), so the three
   surfaces cannot disagree on order or identity. Removal edits exactly one
   config file through the preserving [Config.Config_file.edit] path and never
   touches session state. *)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
module Config = Spice_host.Config
module Config_file = Config.Config_file
module Permission = Spice_host.Permission

let source_location = function
  | Config.Source.User { path }
  | Config.Source.Project { path }
  | Config.Source.Project_local { path }
  | Config.Source.Extra_file { path } ->
      Spice_path.Abs.to_string path
  | Config.Source.Env { name } -> name
  | Config.Source.Override -> "override"
  | Config.Source.Default { reason } -> reason

(* The stable human matcher rendering derives from the matcher's JSON encoding
   ([Match.jsont] is schema; [Rule.pp] is unstable diagnostics): the matcher
   type tag, then its members in codec order. *)
let json_members = function
  | Jsont.Object (members, _) ->
      List.map (fun ((name, _), value) -> (name, value)) members
  | _ -> []

let json_member name json = List.assoc_opt name (json_members json)

let scalar_text = function
  | Jsont.String (value, _) -> value
  | json -> json_string json

let rule_json rule = json_encode Spice_permission.Policy.Rule.jsont rule

let matcher_json matcher =
  json_encode Spice_permission.Policy.Match.jsont matcher

let rule_action_text rule =
  match Spice_permission.Policy.Rule.action rule with
  | Spice_permission.Policy.Rule.Allow -> "allow"
  | Spice_permission.Policy.Rule.Review -> "review"
  | Spice_permission.Policy.Rule.Deny -> "deny"

let rule_matcher_text rule =
  let matcher = Spice_permission.Policy.Rule.matcher rule in
  let members = json_members (matcher_json matcher) in
  let type_tag =
    match List.assoc_opt "type" members with
    | Some tag -> scalar_text tag
    | None -> "unknown"
  in
  let fields =
    List.filter_map
      (fun (name, value) ->
        if String.equal name "type" then None
        else Some (name ^ "=" ^ scalar_text value))
      members
  in
  String.concat " " (type_tag :: fields)

let list_rows host = Permission.Run.rows (permission_args host None)

let list_text host =
  match list_rows host with
  | [] -> stdout_printf "no permission rules\n"
  | rows ->
      print_table
        ~header:[ "#"; "RULE"; "ACTION"; "MATCH"; "SOURCE" ]
        (List.mapi
           (fun index row ->
             [
               string_of_int (index + 1);
               row.Permission.Run.id;
               rule_action_text row.Permission.Run.rule;
               rule_matcher_text row.Permission.Run.rule;
               source_kind_string row.Permission.Run.source
               ^ " "
               ^ source_location row.Permission.Run.source;
             ])
           rows)

let list_json host =
  let rules =
    List.mapi
      (fun index row ->
        json_obj
          [
            ("position", Jsont.Json.int (index + 1));
            ("id", Jsont.Json.string row.Permission.Run.id);
            ("rule", rule_json row.Permission.Run.rule);
            ( "source",
              Jsont.Json.string (source_kind_string row.Permission.Run.source)
            );
            ( "location",
              Jsont.Json.string (source_location row.Permission.Run.source) );
          ])
      (list_rows host)
  in
  stdout_printf "%s\n"
    (json_string
       (json_envelope ~type_:"permission.rules"
          [ ("rules", Jsont.Json.list rules) ]))

let list json cwd =
  with_host ?cwd @@ fun ~stdenv:_ host ->
  status
    (if json then list_json host else list_text host;
     Ok Success)

(* Removal: the id is resolved against the writable file layers only. An id
   present in several layers is ambiguous and requires --from; an id only in
   a non-writable source (the preset, an extra config file) fails loudly. *)

type from = From_user | From_project | From_project_local

let file_kind_of_source = function
  | Config.Source.User _ -> Some Config_file.User
  | Config.Source.Project _ -> Some Config_file.Project
  | Config.Source.Project_local _ -> Some Config_file.Project_local
  | Config.Source.Extra_file _ | Config.Source.Env _ | Config.Source.Override
  | Config.Source.Default _ ->
      None

let from_matches from source =
  match (from, source) with
  | From_user, Config.Source.User _
  | From_project, Config.Source.Project _
  | From_project_local, Config.Source.Project_local _ ->
      true
  | _ -> false

let kind_string = function
  | Config_file.User -> "user"
  | Config_file.Project -> "project"
  | Config_file.Project_local -> "project-local"

let remove rule_id from cwd =
  with_host ?cwd @@ fun ~stdenv host ->
  status
    (let config = Spice_host.Host.config host in
     let permissions = Config.permissions config in
     let candidates =
       List.filter_map
         (fun (source, rules) ->
           if
             List.exists
               (fun rule -> String.equal (Permission.rule_id rule) rule_id)
               rules
           then Some (source, rules)
           else None)
         (Config.Permissions.rules permissions)
     in
     let candidates =
       match from with
       | None -> candidates
       | Some from ->
           List.filter (fun (source, _) -> from_matches from source) candidates
     in
     match candidates with
     | [] ->
         Error
           (`Runtime
              ("no durable permission rule " ^ rule_id
             ^ "; run `spice permission list` to see rule ids"))
     | _ :: _ :: _ ->
         usage
           ("rule " ^ rule_id ^ " exists in several layers ("
           ^ String.concat ", "
               (List.map
                  (fun (source, _) -> source_kind_string source)
                  candidates)
           ^ "); pass --from to choose one")
     | [ (source, rules) ] -> (
         match file_kind_of_source source with
         | None ->
             Error
               (`Runtime
                  ("rule " ^ rule_id ^ " comes from a non-writable source ("
                 ^ source_kind_string source ^ "); edit that source directly"))
         | Some kind -> (
             let remaining =
               List.filter
                 (fun rule ->
                   not (String.equal (Permission.rule_id rule) rule_id))
                 rules
             in
             let edit =
               Config_file.edit ~stdenv (Config.files config) kind
                 ~f:(fun layer ->
                   Ok (Config_file.set_permission_rules remaining layer))
             in
             match edit with
             | Error error ->
                 Error (`Runtime (Spice_host.Config.Error.message error))
             | Ok () ->
                 stdout_printf "removed rule %s from %s %s\n" rule_id
                   (kind_string kind)
                   (Config_file.path (Config.files config) kind
                   |> Spice_path.Abs.to_string);
                 Ok Success)))

(* Command line *)

let json_flag = Cli_arg.json_flag ~doc:"Print rules as JSON." ()
let cwd = Cli_arg.cwd ~doc:"Run as if invoked from DIR." ()

let rule_id_arg =
  CArg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"RULE_ID" ~doc:"Rule id from `spice permission list`.")

let from_flag =
  let parse = function
    | "user" -> Ok From_user
    | "project" -> Ok From_project
    | "project-local" -> Ok From_project_local
    | raw -> Error (`Msg ("unknown rule layer: " ^ raw))
  in
  let print ppf from =
    Format.pp_print_string ppf
      (match from with
      | From_user -> "user"
      | From_project -> "project"
      | From_project_local -> "project-local")
  in
  CArg.(
    value
    & opt (some (conv (parse, print))) None
    & info [ "from" ] ~docv:"LAYER"
        ~doc:
          "Layer to remove the rule from when the same rule exists in several \
           layers: $(b,user), $(b,project), or $(b,project-local).")

let list_command =
  CCmd.v
    (CCmd.info "list" ~exits
       ~doc:
         "List durable permission rules in evaluation order followed by the \
          fixed product rules.")
    (exit_term CTerm.(const list $ json_flag $ cwd))

let remove_command =
  CCmd.v
    (CCmd.info "remove" ~exits
       ~doc:
         "Remove one durable permission rule from its config file. Rule \
          storage only: saved sessions and replay history are never touched.")
    (exit_term CTerm.(const remove $ rule_id_arg $ from_flag $ cwd))

let group =
  CCmd.group
    (CCmd.info "permission" ~exits ~docs:s_config_commands
       ~doc:"Inspect and edit durable permission rules."
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Durable rules are hand-authored in user or extra config files; \
              this group lists them in evaluation order alongside fixed \
              product rules, and prunes writable rules by id.";
         ])
    [ list_command; remove_command ]
