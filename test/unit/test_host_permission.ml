(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap

module Access = Spice_permission.Access
module Policy = Spice_permission.Policy
module Permission = Spice_host.Permission

let request accesses = Spice_permission.Request.of_accesses accesses

let decide ?(durable = []) ?(conversation = []) ~sandbox_backed preset accesses =
  let run =
    Permission.Run.make ~preset:(`Preset, preset)
      ~durable:(List.map (fun rules -> (`Durable, rules)) durable)
      ()
    |> Permission.Run.with_sandbox_backing ~sandbox_backed
  in
  Policy.decide (Permission.Run.policy ~conversation run) (request accesses)

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

let command ?(execution = Access.Command.Direct) program args =
  Access.argv ~cwd ~execution ~program args

let enforced = Access.Command.Enforced

let sealed_commands_review_by_default () =
  List.iter
    (fun (label, access) ->
      decide ~sandbox_backed:true Permission.Preset.Default [ access ]
      |> expect_review label)
    [
      ("Dune", command ~execution:enforced "dune" [ "build" ]);
      ("Merlin", command ~execution:enforced "ocamlmerlin" [ "type-enclosing" ]);
      ("shell", Access.shell ~cwd ~execution:enforced "printf ok");
    ];
  decide ~sandbox_backed:true Permission.Preset.Accept_edits
    [ command ~execution:enforced "dune" [ "runtest" ] ]
  |> expect_review "accept-edits sealed command"

let explicit_read_anywhere_opt_in () =
  let review_destructive =
    Policy.Rule.review (Policy.Match.command Policy.Match.Command.destructive)
  in
  let allow_enforced =
    Policy.Rule.allow
      (Policy.Match.command
         (Policy.Match.Command.execution Access.Command.Enforced))
  in
  let durable = [ [ review_destructive; allow_enforced ] ] in
  decide ~durable ~sandbox_backed:true Permission.Preset.Default
    [ Access.shell ~cwd ~execution:enforced "cat ~/.config/raven/api.mli" ]
  |> expect_allowed "explicit ordinary sandboxed command";
  decide ~durable ~sandbox_backed:true Permission.Preset.Default
    [ Access.shell ~cwd ~execution:enforced "rm -rf _build" ]
  |> expect_review "destructive rule precedes sandboxed allow";
  decide ~durable ~sandbox_backed:true Permission.Preset.Plan
    [ Access.shell ~cwd ~execution:enforced "cat ~/.config/raven/api.mli" ]
  |> expect_denied "Plan command guard precedes durable sandboxed allow";
  decide ~conversation:[ allow_enforced ] ~sandbox_backed:true
    Permission.Preset.Plan
    [ Access.shell ~cwd ~execution:enforced "cat ~/.config/raven/api.mli" ]
  |> expect_denied "Plan command guard precedes session sandboxed allow"

let unproven_and_sensitive_commands_still_review () =
  decide ~sandbox_backed:true Permission.Preset.Default
    [ command "dune" [ "build" ] ]
  |> expect_review "direct command";
  decide ~sandbox_backed:true Permission.Preset.Default
    [ command ~execution:enforced "rm" [ "-rf"; "_build" ] ]
  |> expect_review "destructive sealed command";
  decide ~sandbox_backed:true Permission.Preset.Default
    [
      Access.shell ~cwd ~execution:Access.Command.Direct "dune build";
      Access.custom ~subject:"dune build" "shell.escalate";
    ]
  |> expect_review "shell escalation"

let posture_and_rule_precedence_are_preserved () =
  List.iter
    (fun posture ->
      decide ~sandbox_backed:false Permission.Preset.Default
        [ command ~execution:enforced "dune" [ "build" ] ]
      |> expect_review posture)
    [ "read-only"; "danger-full-access"; "external-sandbox" ];
  decide ~sandbox_backed:true Permission.Preset.Plan
    [ command ~execution:enforced "dune" [ "build" ] ]
  |> expect_denied "Plan";
  let durable_review =
    Policy.Rule.review (Policy.Match.kind `Command)
  in
  decide ~durable:[ [ durable_review ] ] ~sandbox_backed:true
    Permission.Preset.Default
    [ command ~execution:enforced "dune" [ "build" ] ]
  |> expect_review "durable review"

let conversation_rules_have_explicit_precedence () =
  let commands = Policy.Match.kind `Command in
  let allow = Policy.Rule.allow commands in
  let review = Policy.Rule.review commands in
  decide ~conversation:[ allow ] ~sandbox_backed:false
    Permission.Preset.Default [ command "dune" [ "build" ] ]
  |> expect_allowed "conversation allow precedes product fallback";
  decide ~durable:[ [ review ] ] ~conversation:[ allow ]
    ~sandbox_backed:false Permission.Preset.Default
    [ command "dune" [ "build" ] ]
  |> expect_review "durable review precedes conversation allow"

let () =
  run "spice.host.permission"
    [
      test "sealed commands review under the safe default"
        sealed_commands_review_by_default;
      test "ordered durable rules opt into read-anywhere shell"
        explicit_read_anywhere_opt_in;
      test "unproven and sensitive commands still review"
        unproven_and_sensitive_commands_still_review;
      test "posture and explicit rule precedence are preserved"
        posture_and_rule_precedence_are_preserved;
      test "conversation rules have explicit precedence"
        conversation_rules_have_explicit_precedence;
    ]
