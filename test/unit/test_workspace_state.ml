(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module State = Spice_host.Workspace_state

let expect_ok message = function
  | Ok value -> value
  | Error error -> failf "%s: %s" message error

let manifest_roundtrip () =
  Eio_main.run @@ fun stdenv ->
  let fs = Eio.Stdenv.fs stdenv in
  let root = Filename.concat (Sys.getcwd ()) "project" in
  let data_root = Filename.concat (Sys.getcwd ()) "_build/test-workspace-state" in
  let dir = expect_ok "create" (State.ensure ~fs ~data_root ~root) in
  equal string ~msg:"deterministic directory" (State.dir ~data_root ~root) dir;
  is_true ~msg:"manifest exists"
    (Eio.Path.is_file (Eio.Path.( / ) fs (State.manifest_path dir)));
  equal string ~msg:"idempotent ensure" dir
    (expect_ok "reload" (State.ensure ~fs ~data_root ~root))

let mismatched_manifest_fails () =
  Eio_main.run @@ fun stdenv ->
  let fs = Eio.Stdenv.fs stdenv in
  let cwd = Sys.getcwd () in
  let root = Filename.concat cwd "project-mismatch" in
  let data_root = Filename.concat cwd "_build/test-workspace-state-mismatch" in
  let dir = State.dir ~data_root ~root in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (Eio.Path.( / ) fs dir);
  Eio.Path.save ~create:(`Or_truncate 0o600)
    (Eio.Path.( / ) fs (State.manifest_path dir))
    {|{"version":1,"root":"/another/project"}|};
  match State.ensure ~fs ~data_root ~root with
  | Ok _ -> failf "mismatched manifest was accepted"
  | Error message ->
      is_true ~msg:"diagnostic names mismatch"
        (String.ends_with ~suffix:"workspace root does not match directory key"
           message)

let () =
  run "spice.host.workspace_state"
    [
      test "manifest roundtrip" manifest_roundtrip;
      test "mismatched manifest fails" mismatched_manifest_fails;
    ]
