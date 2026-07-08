(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.host.permission" ~doc:"Permission policy verdicts"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* Rowed once by the Plan preset and compared against by [Run.denial_message]
   to key the plan-mode steering message. *)
let plan_command_deny_rule =
  Spice_permission.Policy.Rule.deny
    (Spice_permission.Policy.Match.kind `Command)

module Preset = struct
  type t = Default | Accept_edits | Plan | Bypass

  let all = [ Default; Accept_edits; Plan; Bypass ]

  let of_string = function
    | "default" -> Some Default
    | "accept-edits" -> Some Accept_edits
    | "plan" -> Some Plan
    | "bypass" -> Some Bypass
    | _ -> None

  let to_string = function
    | Default -> "default"
    | Accept_edits -> "accept-edits"
    | Plan -> "plan"
    | Bypass -> "bypass"

  let rules t =
    let allow op =
      Spice_permission.Policy.Rule.allow
        (Spice_permission.Policy.Match.path ~op
           Spice_permission.Policy.Match.Path.workspace)
    in
    let deny op =
      Spice_permission.Policy.Rule.deny
        (Spice_permission.Policy.Match.path ~op
           Spice_permission.Policy.Match.Path.workspace)
    in
    match t with
    | Default -> [ allow `Read ]
    | Accept_edits ->
        [ allow `Read; allow `Create; allow `Modify; allow `Delete ]
    | Plan ->
        [
          allow `Read;
          deny `Create;
          deny `Modify;
          deny `Delete;
          plan_command_deny_rule;
        ]
    | Bypass -> [ Spice_permission.Policy.Rule.allow_all_dangerously ]

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

module Run = struct
  type 'src row = {
    id : string;
    source : 'src;
    rule : Spice_permission.Policy.Rule.t;
  }

  type 'src t = { preset : Preset.t; rows : 'src row list }

  let annotate source rule = { id = rule_id rule; source; rule }

  (* A durable layer must not name the same rule twice; config validates user
     input upstream, so a duplicate reaching here is a programmer error. *)
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

  let make ~preset:(preset_source, preset) ~durable () =
    let durable = List.concat_map layer_rows durable in
    let preset_rows = List.map (annotate preset_source) (Preset.rules preset) in
    { preset; rows = durable @ preset_rows }

  let preset t = t.preset
  let rows t = t.rows

  let policy t =
    Spice_permission.Policy.make (List.map (fun row -> row.rule) t.rows)

  let find t rule =
    List.find_opt
      (fun row -> Spice_permission.Policy.Rule.equal row.rule rule)
      t.rows

  let denial_message ~source t denial =
    let rule = Spice_permission.Policy.Denial.rule denial in
    Log.debug (fun m ->
        m "permission denied preset=%a rule=%s" Preset.pp t.preset
          (match find t rule with Some row -> row.id | None -> "unmatched"));
    if
      Preset.equal t.preset Preset.Plan
      && Spice_permission.Policy.Rule.equal rule plan_command_deny_rule
    then
      "Permission denied: plan mode does not allow commands. Use the read-only \
       tools (read_file, glob, search_text) to gather information."
    else
      match find t rule with
      | Some row ->
          "Permission denied by policy rule " ^ row.id ^ " ("
          ^ source row.source ^ ")."
      | None -> "Permission denied by policy."
end
