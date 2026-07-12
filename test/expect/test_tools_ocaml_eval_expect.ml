(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Eval = Spice_tools.Ocaml_eval
module Json = Jsont.Json
module Tool = Spice_tool
module Workspace = Spice_workspace

let environment =
  Spice_sandbox.Environment.make
    ~path:(Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin")
    ~scratch:(Spice_path.Abs.of_string_exn "/tmp") ~user_names:[]
    ~launch:Sys.getenv_opt
  |> Result.get_ok

let sandbox =
  Spice_sandbox.seal (Spice_sandbox.Policy.direct ~environment)

let confined ?(writable_roots = []) () =
  Spice_sandbox.Policy.confined ~reads:Spice_sandbox.Policy.All
    ~writable_roots ~protected_meta:[] ~protected_paths:[]
    ~network:Spice_sandbox.Policy.Network.Restricted ~environment

let fake_backend =
  Spice_sandbox.Backend.make ~id:"fake"
    ~available:(fun () -> Ok ())
    ~prepare:(fun _policy ->
      Ok
        (Spice_sandbox.Backend.prepared ~chdir:false ~prefix:[]
           ~profile:(Spice_digest.string "canonical")))
    ()

let enforced_sandbox =
  Spice_sandbox.seal ~backend:fake_backend (confined ())

let external_sandbox =
  Spice_sandbox.seal (Spice_sandbox.Policy.external_ ~environment)

let refused_sandbox =
  Spice_sandbox.seal (confined ())

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid absolute test path %S: %s" path
        (Spice_path.Error.message error)

let path root rel = Filename.concat root rel

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stats -> (
      match stats.Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun name ->
              if (not (String.equal name ".")) && not (String.equal name "..")
              then rm_rf (Filename.concat path name));
          Unix.rmdir path
      | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Unix.unlink path)

let mkdir_p dir =
  let rec loop dir =
    if Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  loop dir

let write_disk file contents =
  mkdir_p (Filename.dirname file);
  let oc = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc contents;
      flush oc)

let with_temp_dir f =
  let dir = Filename.temp_file "spice-ocaml-eval-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_project root =
  write_disk (path root "dune-project") "(lang dune 3.0)\n(name fixture)\n";
  write_disk (path root "lib/dune") "(library (name fixture_lib))\n";
  write_disk (path root "lib/fixture_lib.ml") "let answer = 42\n"

let with_project f =
  with_temp_dir @@ fun root ->
  let root = Unix.realpath root in
  write_project root;
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env -> f ~root ~fs:(Eio.Stdenv.fs env) ~workspace

let write_executable file contents =
  write_disk file contents;
  Unix.chmod file 0o755

let decode_call tool input =
  match Tool.Call.decode [ tool ] ~name:Eval.name ~input () with
  | Ok call -> call
  | Error error -> failf "decode failed: %a" Tool.Error.pp error

let execution_name = function
  | Spice_permission.Access.Command.Direct -> "direct"
  | Spice_permission.Access.Command.Enforced -> "enforced"
  | Spice_permission.Access.Command.External -> "external"

let print_command_routes label call =
  let routes =
    Tool.Call.permissions call
    |> List.concat_map Spice_permission.Request.accesses
    |> List.filter_map (function
         | Spice_permission.Access.Command command ->
             Some
               (execution_name
                  (Spice_permission.Access.Command.execution command))
         | Spice_permission.Access.Path _ | Spice_permission.Access.Network _
         | Spice_permission.Access.Custom _ ->
             None)
  in
  Printf.printf "%s: %s\n" label (String.concat "," routes)

let print_status result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> print_endline "status: completed"
  | Tool.Result.Failed { kind; message; metadata } ->
      ignore metadata;
      Printf.printf "status: failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "status: interrupted cancelled=%b: %s\n" cancelled reason

let stream_text = function
  | Eval.Output.Complete text -> text
  | Eval.Output.Truncated { head; tail; omitted_bytes } ->
      head ^ Printf.sprintf "\n... %d omitted ...\n" omitted_bytes ^ tail

let print_eval_result result =
  print_status result;
  match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Eval.Output.of_tool_output output with
      | None -> print_endline "typed: none"
      | Some evidence ->
          Printf.printf "stage: %s\n"
            (match Eval.Output.stage evidence with
            | Eval.Output.Dune_top -> "dune_top"
            | Eval.Output.Eval -> "eval");
          Printf.printf "dir: %s\n"
            (Workspace.Path.display (Eval.Output.dir evidence));
          let stdout = stream_text (Eval.Output.stdout evidence) in
          Printf.printf "stdout has answer: %b\n"
            (String.contains stdout '4' && String.contains stdout '3');
          Printf.printf "truncated: %b\n" (Tool.Output.truncated output))

let%expect_test "ocaml_eval evaluates code in a Dune library context" =
  with_project @@ fun ~root:_ ~fs ~workspace ->
  let config = Eval.Config.make ~default_timeout_ms:30_000 () in
  let tool = Eval.tool ~sandbox ~fs ~workspace ~config () in
  let input =
    json_obj
      [
        ("dir", Json.string "lib");
        ("code", Json.string {|Printf.printf "%d\n%!" (Fixture_lib.answer + 1)|});
      ]
  in
  let call = decode_call tool input in
  Printf.printf "tool: %s\n" (Tool.Call.tool call);
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let model_code_access =
    Tool.Call.permissions call
    |> List.concat_map Spice_permission.Request.accesses
    |> List.exists (function
         | Spice_permission.Access.Command
             (Spice_permission.Access.Command.Code
               { language = "ocaml"; source; _ }) ->
             String.equal source
               {|Printf.printf "%d\n%!" (Fixture_lib.answer + 1)|}
         | Spice_permission.Access.Command _ ->
             false
         | Spice_permission.Access.Path _
         | Spice_permission.Access.Network _
         | Spice_permission.Access.Custom _ ->
             false)
  in
  Printf.printf "model code access: %b\n" model_code_access;
  Tool.Call.run call () |> print_eval_result;
  [%expect
    {|
    tool: ocaml_eval
    permissions: 1
    model code access: true
    status: completed
    stage: eval
    dir: lib
    stdout has answer: true
    truncated: false |}]

let%expect_test "eval source carries the exact sandbox route" =
  with_project @@ fun ~root:_ ~fs ~workspace ->
  let config = Eval.Config.make () in
  let input = json_obj [ ("code", Json.string "1 + 1") ] in
  let call sandbox =
    Eval.tool ~sandbox ~fs ~workspace ~config () |> fun tool ->
    decode_call tool input
  in
  print_command_routes "unconfined" (call sandbox);
  print_command_routes "external" (call external_sandbox);
  print_command_routes "enforced" (call enforced_sandbox);
  print_command_routes "refused" (call refused_sandbox);
  [%expect
    {|
    unconfined: direct
    external: external
    enforced: enforced
    refused: |}]

let%expect_test "ocaml_eval rejects unknown input fields" =
  with_project @@ fun ~root:_ ~fs ~workspace ->
  let config = Eval.Config.make () in
  let tool = Eval.tool ~sandbox ~fs ~workspace ~config () in
  let input =
    json_obj [ ("code", Json.string "1 + 1"); ("extra", Json.bool true) ]
  in
  begin match Tool.Call.decode [ tool ] ~name:Eval.name ~input () with
  | Ok _ -> print_endline "unknown input: accepted"
  | Error _ -> print_endline "unknown input: rejected"
  end;
  [%expect {| unknown input: rejected |}]

let%expect_test "ocaml_eval cancellation stops before spawning" =
  with_project @@ fun ~root:_ ~fs ~workspace ->
  let config = Eval.Config.make () in
  let input = Eval.Input.make "1 + 1" in
  Eval.run ~sandbox ~fs ~workspace ~config ~cancelled:(fun () -> true) input
  |> print_status;
  [%expect {| status: interrupted cancelled=true: tool call cancelled |}]

let%expect_test "ocaml_eval timeout applies while writing large stdin" =
  with_project @@ fun ~root ~fs ~workspace ->
  let dune = path root "fake-dune" in
  let ocaml = path root "fake-ocaml" in
  write_executable dune "#!/bin/sh\nexit 0\n";
  write_executable ocaml "#!/bin/sh\nsleep 5\n";
  let config =
    Eval.Config.make ~dune ~ocaml ~default_timeout_ms:50 ~max_timeout_ms:50 ()
  in
  let input = Eval.Input.make (String.make (2 * 1024 * 1024) 'x') in
  Eval.run ~sandbox ~fs ~workspace ~config input |> print_status;
  [%expect {| status: failed timed_out: OCaml eval timed out after 50ms |}]

let%expect_test "ocaml_eval refuses to run under a live dune watch" =
  with_project @@ fun ~root ~fs ~workspace ->
  print_endline "-- watch holds the lock --";
  let config = Eval.Config.make () in
  Eval.run ~sandbox ~fs ~workspace ~config
    ~watch:(fun () -> Some "dune-rpc:socket")
    (Eval.Input.make "1 + 1")
  |> print_status;
  print_endline "-- no watch proceeds --";
  let dune = path root "fake-dune" in
  let ocaml = path root "fake-ocaml" in
  write_executable dune "#!/bin/sh\nexit 0\n";
  write_executable ocaml "#!/bin/sh\ncat >/dev/null\n";
  let config = Eval.Config.make ~dune ~ocaml () in
  Eval.run ~sandbox ~fs ~workspace ~config
    ~watch:(fun () -> None)
    (Eval.Input.make "1 + 1")
  |> print_status;
  [%expect
    {|
    -- watch holds the lock --
    status: failed unavailable: ocaml_eval cannot run while a Dune watch (dune-rpc:socket) holds the build lock: `dune ocaml top` takes the same lock and fails fast rather than sharing it. Stop the watch, or run the evaluation outside this session, and retry.
    -- no watch proceeds --
    status: completed |}]

[%%run_tests "spice.tools.ocaml_eval.expect"]
