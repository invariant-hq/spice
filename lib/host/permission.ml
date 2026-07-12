(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.host.permission" ~doc:"Permission policy verdicts"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Review_behavior = struct
  type t = Default | Bypass

  let all = [ Default; Bypass ]

  let of_string = function
    | "default" -> Some Default
    | "bypass" -> Some Bypass
    | _ -> None

  let to_string = function Default -> "default" | Bypass -> "bypass"
  let equal = ( = )
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Unattended = struct
  type t = Block | Deny

  let all = [ Block; Deny ]

  let of_string = function
    | "block" -> Some Block
    | "deny" -> Some Deny
    | _ -> None

  let to_string = function Block -> "block" | Deny -> "deny"
  let equal = ( = )
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

let rule_id rule =
  Spice_digest.key ~length:12 ~domain:"spice.permission.rule.v1"
    [ Spice_permission.Policy.Rule.stable_text rule ]

let web_docs_allowlist =
  [
    "docs.rs";
    "doc.rust-lang.org";
    "developer.mozilla.org";
    "pkg.go.dev";
    "docs.python.org";
    "ocaml.org";
    "v2.ocaml.org";
    "man7.org";
    "www.gnu.org";
  ]

module Run = struct
  type 'src row = {
    id : string;
    source : 'src;
    rule : Spice_permission.Policy.Rule.t;
  }

  type 'src t = {
    review_behavior : Review_behavior.t;
    durable : 'src row list;
    product : 'src row list;
  }

  let annotate source rule = { id = rule_id rule; source; rule }

  let layer_rows (source, rules) =
    let rows = List.map (annotate source) rules in
    let rec check seen = function
      | [] -> ()
      | row :: rest ->
          if List.mem row.id seen then
            invalid_arg
              ("Spice_host.Permission.Run.make: duplicate rule in one layer: "
             ^ row.id);
          check (row.id :: seen) rest
    in
    check [] rows;
    rows

  let workspace_rule op =
    Spice_permission.Policy.Rule.allow
      (Spice_permission.Policy.Match.path ~op
         Spice_permission.Policy.Match.Path.workspace)

  let documentation_rule host =
    Spice_permission.Policy.Rule.allow
      (Spice_permission.Policy.Match.network_host ~host ())

  let command_execution_rule execution =
    Spice_permission.Policy.Rule.allow
      (Spice_permission.Policy.Match.command
         (Spice_permission.Policy.Match.Command.execution execution))

  let project_execution write =
    Spice_permission.Access.Command.Enforced
      Spice_permission.Access.Command.Confinement.
        {
          read = Project;
          write;
          network = Restricted;
        }

  let product_rules =
    Spice_permission.Policy.Rule.review
      (Spice_permission.Policy.Match.command
         Spice_permission.Policy.Match.Command.high_impact)
    :: List.map command_execution_rule
         [
           project_execution
             Spice_permission.Access.Command.Confinement.Read_only;
           project_execution
             Spice_permission.Access.Command.Confinement.Workspace;
           Spice_permission.Access.Command.External;
         ]
    @ List.map workspace_rule [ `Read; `Create; `Modify; `Delete ]
    @ List.map documentation_rule web_docs_allowlist

  let make ~review ~product ~durable () =
    {
      review_behavior = review;
      durable = List.concat_map layer_rows durable;
      product = List.map (annotate product) product_rules;
    }

  let review_behavior t = t.review_behavior

  let on_review t =
    match t.review_behavior with
    | Review_behavior.Default -> Spice_permission.Policy.Ask
    | Review_behavior.Bypass -> Spice_permission.Policy.Allow

  let rows t = t.durable @ t.product

  let policy ~conversation t =
    let durable = List.map (fun row -> row.rule) t.durable in
    let product = List.map (fun row -> row.rule) t.product in
    Spice_permission.Policy.make (durable @ conversation @ product)

  let find t rule =
    List.find_opt
      (fun row -> Spice_permission.Policy.Rule.equal row.rule rule)
      (rows t)

  let denial_message ~source t denial =
    let rule = Spice_permission.Policy.Denial.rule denial in
    Log.debug (fun m ->
        m "permission denied review=%a rule=%s" Review_behavior.pp
          t.review_behavior
          (match find t rule with Some row -> row.id | None -> "unmatched"));
    match find t rule with
    | Some row ->
        "Permission denied by policy rule " ^ row.id ^ " ("
        ^ source row.source ^ ")."
    | None -> "Permission denied by policy."
end
