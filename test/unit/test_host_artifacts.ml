(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Artifacts = Spice_host.Artifacts
module Protocol = Spice_protocol
module Session = Spice_session

let fail_error context error =
  failf "%s: %a" context Artifacts.Error.pp error

let ok context = function
  | Ok value -> value
  | Error error -> fail_error context error

let ok_string context = function
  | Ok value -> value
  | Error message -> failf "%s: %s" context message

let spawn =
  match
    Protocol.Subagent.Spawn.make ~role:Protocol.Subagent.Role.Explore
      ~task:"Inspect artifact identity." ()
  with
  | Ok spawn -> spawn
  | Error error -> failwith error

let subagent_run child =
  match
    Protocol.Subagent_run.make ~child:(Session.Id.of_string child)
      ~parent:(Session.Id.of_string "parent")
      ~parent_turn:(Session.Turn.Id.of_string "turn-1")
      ~parent_call_id:("call-" ^ child) ~spawn ~depth:1
      ~created_at:(Session.Time.of_unix_ms 1L) ()
  with
  | Ok run -> run
  | Error error -> failwith error

let plan id =
  let source =
    ok_string "plan source"
      (Protocol.Plan.Source.make
         ~session:(Session.Id.of_string "parent")
         ~turn:(Session.Turn.Id.of_string "turn-1") ())
  in
  ok_string "plan"
    (Protocol.Plan.propose
       ~id:(ok_string "plan id" (Protocol.Plan.Id.of_string id))
       ~source ~body:"Inspect the artifact store."
       ~created_at:(Session.Time.of_unix_ms 1L) ())

let with_root name test =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let root = Filename.temp_dir ("spice_artifacts_" ^ name) "" in
  test ~fs ~root

let path fs name = Eio.Path.( / ) fs name

let expect_corrupt_path expected = function
  | Error (Artifacts.Error.Corrupt_file { path; _ }) ->
      equal string ~msg:"corruption names the physical entry" expected path
  | Error error -> fail_error "wrong artifact error" error
  | Ok _ -> failf "misnamed artifact should be rejected"

let plan_list_rejects_filename_key_mismatch () =
  with_root "plan_filename_key" @@ fun ~fs ~root ->
  ok "create plan" (Artifacts.Plan.create ~fs ~root (plan "plan-a"));
  let dir = Filename.concat root "plans/parent" in
  let original = Filename.concat dir "plan-a.json" in
  let renamed = Filename.concat dir "plan-b.json" in
  Eio.Path.rename (path fs original) (path fs renamed);
  Artifacts.Plan.list ~fs ~root ~session:(Session.Id.of_string "parent")
  |> expect_corrupt_path renamed

let plan_list_decodes_filename_components () =
  with_root "plan_filename_escape" @@ fun ~fs ~root ->
  ok "create plan" (Artifacts.Plan.create ~fs ~root (plan "plan/one"));
  let plans =
    ok "list plans"
      (Artifacts.Plan.list ~fs ~root
         ~session:(Session.Id.of_string "parent"))
  in
  equal (list string) ~msg:"escaped plan id round-trips through listing"
    [ "plan/one" ]
    (List.map
       (fun plan -> Protocol.Plan.Id.to_string (Protocol.Plan.id plan))
       plans)

let subagent_list_rejects_filename_key_mismatch () =
  with_root "subagent_filename_key" @@ fun ~fs ~root ->
  ok "put subagent run"
    (Artifacts.Subagent_run.put ~fs ~root (subagent_run "child-a"));
  let dir = Filename.concat root "subagents/parent" in
  let original = Filename.concat dir "child-a.json" in
  let renamed = Filename.concat dir "child-b.json" in
  Eio.Path.rename (path fs original) (path fs renamed);
  Artifacts.Subagent_run.list ~fs ~root
    ~parent:(Session.Id.of_string "parent")
  |> expect_corrupt_path renamed

let children_decode_filename_components () =
  with_root "children_decode" @@ fun ~fs ~root ->
  let ids = [ "team/child"; "percent%child"; "space child"; "café" ] in
  List.iter
    (fun id ->
      ok "put subagent run"
        (Artifacts.Subagent_run.put ~fs ~root (subagent_run id)))
    ids;
  let actual =
    ok "list child ids" (Artifacts.Subagent_run.children ~fs ~root)
    |> List.map Session.Id.to_string |> List.sort String.compare
  in
  equal (list string) ~msg:"child ids round-trip through artifact filenames"
    (List.sort String.compare ids) actual;
  let listed =
    ok "list subagent runs"
      (Artifacts.Subagent_run.list ~fs ~root
         ~parent:(Session.Id.of_string "parent"))
    |> List.map (fun run ->
        Spice_protocol.Subagent_run.child run |> Session.Id.to_string)
    |> List.sort String.compare
  in
  equal (list string) ~msg:"escaped child ids survive keyed listing"
    (List.sort String.compare ids) listed

let children_reject_malformed_escape () =
  with_root "children_bad_escape" @@ fun ~fs ~root ->
  let dir = Filename.concat root "subagents/parent" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (path fs dir);
  Eio.Path.save ~create:(`Exclusive 0o600)
    (path fs (Filename.concat dir "bad%ZZ.json"))
    "not decoded";
  match Artifacts.Subagent_run.children ~fs ~root with
  | Error (Artifacts.Error.Corrupt_file _) -> ()
  | Error error -> fail_error "malformed escape returned the wrong error" error
  | Ok _ -> failf "malformed child filename should be rejected"

let () =
  run "spice.host.artifacts"
    [
      test "plan list rejects a filename key mismatch"
        plan_list_rejects_filename_key_mismatch;
      test "plan list decodes filename components"
        plan_list_decodes_filename_components;
      test "subagent list rejects a filename key mismatch"
        subagent_list_rejects_filename_key_mismatch;
      test "children decode filename components"
        children_decode_filename_components;
      test "children reject malformed escapes" children_reject_malformed_escape;
    ]
