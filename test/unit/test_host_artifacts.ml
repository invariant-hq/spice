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

let with_root name test =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let root = Filename.temp_dir ("spice_artifacts_" ^ name) "" in
  test ~fs ~root

let path fs name = Eio.Path.( / ) fs name

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
    (List.sort String.compare ids) actual

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
      test "children decode filename components"
        children_decode_filename_components;
      test "children reject malformed escapes" children_reject_malformed_escape;
    ]
