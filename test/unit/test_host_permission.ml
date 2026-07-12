(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap

module Access = Spice_permission.Access
module Policy = Spice_permission.Policy
module Permission = Spice_host.Permission

let request accesses = Spice_permission.Request.of_accesses accesses

let make_run ?(review = Permission.Review_behavior.Default) ?(durable = []) () =
  Permission.Run.make ~review ~product:`Product
    ~durable:(List.map (fun rules -> (`Durable, rules)) durable)
    ()

let decide ?review ?durable ?(conversation = []) accesses =
  let run = make_run ?review ?durable () in
  Policy.decide ~on_review:(Permission.Run.on_review run)
    (Permission.Run.policy ~conversation run)
    (request accesses)

let expect_allowed message = function
  | Policy.Decision.Allowed -> ()
  | Policy.Decision.Review _ -> failf "%s: expected allow, got review" message
  | Policy.Decision.Denied _ -> failf "%s: expected allow, got deny" message

let expect_review message = function
  | Policy.Decision.Review _ -> ()
  | Policy.Decision.Allowed -> failf "%s: expected review, got allow" message
  | Policy.Decision.Denied _ -> failf "%s: expected review, got deny" message

let expect_denied message = function
  | Policy.Decision.Denied _ -> ()
  | Policy.Decision.Allowed -> failf "%s: expected deny, got allow" message
  | Policy.Decision.Review _ -> failf "%s: expected deny, got review" message

let cwd = Access.Path_scope.unknown "test-cwd"

let enforced ?(read = Access.Command.Confinement.Project)
    ?(write = Access.Command.Confinement.Read_only)
    ?(network = Access.Command.Confinement.Restricted) () =
  Access.Command.Enforced Access.Command.Confinement.{ read; write; network }

let command ?(execution = Access.Command.Direct) program args =
  Access.argv ~cwd ~execution ~program args

let default_credits_only_safe_execution_boundaries () =
  decide [ command ~execution:(enforced ()) "dune" [ "build" ] ]
  |> expect_allowed "project read-only command";
  decide
    [
      command
        ~execution:(enforced ~write:Access.Command.Confinement.Workspace ())
        "dune" [ "build" ];
    ]
  |> expect_allowed "project workspace-write command";
  decide
    [ command ~execution:Access.Command.External "dune" [ "build" ] ]
  |> expect_allowed "external command";
  decide
    [
      command ~execution:(enforced ~read:Access.Command.Confinement.All ())
        "dune" [ "build" ];
    ]
  |> expect_review "read-all command";
  decide
    [
      command
        ~execution:(enforced ~network:Access.Command.Confinement.Enabled ())
        "dune" [ "build" ];
    ]
  |> expect_review "network-enabled command";
  decide [ Access.shell ~cwd ~execution:Access.Command.Direct "git status" ]
  |> expect_review "direct command";
  decide
    [ Access.code ~cwd ~execution:(enforced ()) ~language:"ocaml" "1" ]
  |> expect_allowed "confined code evaluation";
  decide [ command ~execution:(enforced ()) "rm" [ "-rf"; "_build" ] ]
  |> expect_review "high-impact command"

let bypass_allows_review_but_not_deny () =
  let commands = Policy.Match.kind `Command in
  decide ~review:Permission.Review_behavior.Bypass
    ~durable:[ [ Policy.Rule.review commands ] ]
    [ command "dune" [ "build" ] ]
  |> expect_allowed "explicit review";
  decide ~review:Permission.Review_behavior.Bypass
    [ Access.custom "unmatched" ]
  |> expect_allowed "unmatched access";
  decide ~review:Permission.Review_behavior.Bypass
    [ command ~execution:(enforced ()) "rm" [ "-rf"; "_build" ] ]
  |> expect_allowed "product high-impact review";
  decide ~review:Permission.Review_behavior.Bypass
    ~durable:[ [ Policy.Rule.deny commands ] ]
    [ command "dune" [ "build" ] ]
  |> expect_denied "explicit deny"

let review_behavior_matches_native_edits_and_direct_shells () =
  let root =
    Spice_workspace.Root.make (Spice_path.Abs.of_string_exn "/workspace")
  in
  let path = Spice_workspace.Path.make ~root Spice_path.Rel.root in
  let edit = Access.path ~op:`Modify path in
  decide [ edit ] |> expect_allowed "default native edit";
  decide ~review:Permission.Review_behavior.Bypass [ edit ]
  |> expect_allowed "bypass native edit";
  decide [ Access.shell ~cwd ~execution:Access.Command.Direct "echo ask" ]
  |> expect_review "default direct shell";
  decide ~review:Permission.Review_behavior.Bypass
    [ Access.shell ~cwd ~execution:Access.Command.Direct "echo bypass" ]
  |> expect_allowed "bypass direct shell"

let durable_rules_precede_conversation_and_product () =
  let commands = Policy.Match.kind `Command in
  let allow = Policy.Rule.allow commands in
  let review = Policy.Rule.review commands in
  decide ~conversation:[ allow ] [ command "dune" [ "build" ] ]
  |> expect_allowed "conversation allow precedes product fallback";
  decide ~conversation:[ allow ]
    [ command ~execution:(enforced ()) "rm" [ "-rf"; "_build" ] ]
  |> expect_allowed "conversation allow precedes high-impact interlock";
  decide ~durable:[ [ review ] ] ~conversation:[ allow ]
    [ command "dune" [ "build" ] ]
  |> expect_review "durable review precedes conversation allow"

let product_rows_have_one_source_and_stable_identity () =
  let run = make_run () in
  let rows = Permission.Run.rows run in
  is_true ~msg:"product rows exist" (not (List.is_empty rows));
  List.iter
    (fun row ->
      equal string ~msg:"row identity follows its rule"
        (Permission.rule_id row.Permission.Run.rule)
        row.Permission.Run.id;
      match row.Permission.Run.source with
      | `Product -> ()
      | `Durable -> fail "product row has durable provenance")
    rows

let () =
  run "spice.host.permission"
    [
      test "default credits only safe execution boundaries"
        default_credits_only_safe_execution_boundaries;
      test "bypass allows reviews but preserves denials"
        bypass_allows_review_but_not_deny;
      test "review behavior keeps native edits and controls direct shells"
        review_behavior_matches_native_edits_and_direct_shells;
      test "durable rules precede conversation and product rules"
        durable_rules_precede_conversation_and_product;
      test "product rows carry stable identity and provenance"
        product_rows_have_one_source_and_stable_identity;
    ]
