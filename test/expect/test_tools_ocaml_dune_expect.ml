(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Describe = Spice_tools.Ocaml_dune_describe
module Diagnostics = Spice_tools.Ocaml_dune_diagnostics
module Dune = Spice_ocaml_dune
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

let confined () =
  Spice_sandbox.Policy.confined ~reads:Spice_sandbox.Policy.All
    ~writable_roots:[] ~protected_meta:[] ~protected_paths:[]
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

let prepare ~cwd ~argv =
  let () = Unix.access (Spice_path.Abs.to_string cwd) [ Unix.F_OK ] in
  Ok (argv, Unix.environment ())

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
  let dir = Filename.temp_file "spice-ocaml-dune-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_project root =
  write_disk (path root "dune-project") "(lang dune 3.0)\n(name fixture)\n";
  write_disk (path root "lib/dune") "(library (name fixture_lib))\n";
  write_disk (path root "lib/fixture_lib.ml") "let answer = 42\n";
  write_disk (path root "test/dune") "(test (name fixture_test))\n";
  write_disk
    (path root "test/fixture_test.ml")
    "let () = assert (Fixture_lib.answer = 42)\n"

let write_greeter_project root =
  write_disk (path root "dune-project")
    "(lang dune 3.0)\n(name nested_fixture)\n";
  write_disk (path root "lib/dune") "(library (name nested_greeter))\n";
  write_disk (path root "lib/nested_greeter.ml") "let greeting name = name\n"

let with_project f =
  with_temp_dir @@ fun root ->
  let root = Unix.realpath root in
  write_project root;
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env ->
  f ~root ~fs:(Eio.Stdenv.fs env)
    ~process_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env)
    ~cwd:(Eio.Path.( / ) (Eio.Stdenv.fs env) root)
    ~net:(Eio.Stdenv.net env) ~workspace

let with_project_clock f =
  with_temp_dir @@ fun root ->
  let root = Unix.realpath root in
  write_project root;
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env ->
  f ~root
    ~process_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env)
    ~cwd:(Eio.Path.( / ) (Eio.Stdenv.fs env) root)
    ~workspace

let with_nested_project_clock f =
  with_temp_dir @@ fun parent ->
  let parent = Unix.realpath parent in
  write_project parent;
  let child = path parent "child" in
  write_greeter_project child;
  let workspace = Workspace.single (Workspace.Root.make (abs child)) in
  Eio_main.run @@ fun env ->
  f ~parent ~child
    ~process_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env)
    ~cwd:(Eio.Path.( / ) (Eio.Stdenv.fs env) child)
    ~workspace

let decode_call tool ~name =
  match Tool.Call.decode [ tool ] ~name ~input:(json_obj []) () with
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

let print_status_kind result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> print_endline "status: completed"
  | Tool.Result.Failed { kind; message; metadata } ->
      ignore (message, metadata);
      Printf.printf "status: failed %s\n" (Tool.Result.failure_to_string kind)
  | Tool.Result.Interrupted { reason; cancelled } ->
      ignore reason;
      Printf.printf "status: interrupted cancelled=%b\n" cancelled

let print_describe_result result =
  print_status result;
  match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output ->
      begin match Spice_tools.Evidence.of_output output with
      | Some (Spice_tools.Evidence.Ocaml_dune_describe evidence) ->
          Printf.printf "components: %d\n"
            (Describe.Output.component_count evidence);
          Printf.printf "tests: %d\n" (Describe.Output.test_count evidence)
      | Some _ -> print_endline "evidence: wrong tool"
      | None -> print_endline "evidence: none"
      end;
      let lines = String.split_on_char '\n' (Tool.Output.text output) in
      List.iteri
        (fun index line ->
          if index < 4 then Printf.printf "line%d: %s\n" (index + 1) line)
        lines

let%expect_test "ocaml_dune_describe runs dune describe for a tiny project" =
  with_project_clock @@ fun ~root ~process_mgr ~clock ~cwd ~workspace ->
  ignore root;
  let tool = Describe.tool ~sandbox ~process_mgr ~clock ~cwd ~workspace () in
  let call = decode_call tool ~name:Describe.name in
  Printf.printf "tool: %s\n" (Tool.Call.tool call);
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  Tool.Call.run call () |> print_describe_result;
  [%expect
    {|
    tool: ocaml_dune_describe
    permissions: 1
    status: completed
    components: 1
    tests: 1
    line1: OCaml Dune project
    line2: root: .
    line3: build_context: _build/default
    line4: components: 1 local=1 external=0 |}]

let%expect_test "Dune implementation argv is not a permission fact" =
  with_project_clock @@ fun ~root:_ ~process_mgr ~clock ~cwd ~workspace ->
  let call sandbox =
    Describe.tool ~sandbox ~process_mgr ~clock ~cwd ~workspace ()
    |> decode_call ~name:Describe.name
  in
  print_command_routes "unconfined" (call sandbox);
  print_command_routes "external" (call external_sandbox);
  print_command_routes "enforced" (call enforced_sandbox);
  [%expect
    {|
    unconfined:
    external:
    enforced: |}]

let%expect_test
    "ocaml_dune_describe roots dune describe at a nested project cwd" =
  with_nested_project_clock
  @@ fun ~parent ~child ~process_mgr ~clock ~cwd ~workspace ->
  ignore (parent, child);
  let tool = Describe.tool ~sandbox ~process_mgr ~clock ~cwd ~workspace () in
  let call = decode_call tool ~name:Describe.name in
  Tool.Call.run call () |> print_describe_result;
  [%expect
    {|
    status: completed
    components: 1
    tests: 0
    line1: OCaml Dune project
    line2: root: .
    line3: build_context: _build/default
    line4: components: 1 local=1 external=0 |}]

let%expect_test "ocaml_dune_describe captures dune stderr" =
  with_project_clock @@ fun ~root ~process_mgr ~clock ~cwd ~workspace ->
  ignore root;
  with_temp_dir @@ fun fake_bin ->
  let fake_dune = path fake_bin "dune" in
  write_disk fake_dune "#!/bin/sh\necho 'captured dune stderr' >&2\nexit 17\n";
  Unix.chmod fake_dune 0o755;
  let old_path = Sys.getenv_opt "PATH" |> Option.value ~default:"" in
  Unix.putenv "PATH" (fake_bin ^ ":" ^ old_path);
  begin
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
        match
          Dune.Describe.describe_project ~prepare ~process_mgr ~clock ~cwd
            ~workspace ()
        with
        | Ok project ->
            ignore project;
            print_endline "unexpected success"
        | Error (Dune.Error.Command_failed { status; stderr; _ }) ->
            Printf.printf "status: %s\n"
              (match status with
              | None -> "none"
              | Some code -> string_of_int code);
            Printf.printf "stderr: %s\n" stderr
        | Error error ->
            Printf.printf "other error: %s\n" (Dune.Error.message error))
  end;
  [%expect {|
    status: 17
    stderr: captured dune stderr |}]

let%expect_test "ocaml_dune_diagnostics exposes a stable bounded tool contract"
    =
  with_project @@ fun ~root ~fs ~process_mgr:_ ~clock ~cwd:_ ~net ~workspace ->
  ignore root;
  let dune = Spice_ocaml_dune.Rpc.Instance.create ~fs ~net ~workspace () in
  let tool = Diagnostics.tool ~clock ~dune () in
  let call = decode_call tool ~name:Diagnostics.name in
  Printf.printf "tool: %s\n" (Tool.Call.tool call);
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  Tool.Call.run call ~cancelled:(fun () -> true) () |> print_status;
  begin match
    Tool.Call.decode [ tool ] ~name:Diagnostics.name
      ~input:(json_obj [ ("extra", Json.bool true) ])
      ()
  with
  | Ok _ -> print_endline "unknown input: accepted"
  | Error _ -> print_endline "unknown input: rejected"
  end;
  [%expect
    {|
    tool: ocaml_dune_diagnostics
    permissions: 1
    status: interrupted cancelled=true: tool call cancelled
    unknown input: rejected |}]

let%expect_test
    "ocaml_dune_diagnostics reports unavailable without a matching Dune RPC \
     instance" =
  with_project @@ fun ~root ~fs ~process_mgr:_ ~clock ~cwd:_ ~net ~workspace ->
  ignore root;
  let dune = Spice_ocaml_dune.Rpc.Instance.create ~fs ~net ~workspace () in
  let tool = Diagnostics.tool ~clock ~dune () in
  let call = decode_call tool ~name:Diagnostics.name in
  Tool.Call.run call () |> print_status_kind;
  [%expect {| status: failed unavailable |}]

let%expect_test "ocaml_dune_diagnostics does not start the shared Dune instance"
    =
  with_project @@ fun ~root ~fs ~process_mgr:_ ~clock ~cwd:_ ~net ~workspace ->
  ignore root;
  let starts = ref 0 in
  let start () =
    incr starts;
    Ok ()
  in
  let start = Spice_ocaml_dune.Rpc.Instance.Start.make start in
  let dune =
    Spice_ocaml_dune.Rpc.Instance.create ~fs ~net ~workspace ~start
      ~sleep:(fun _ -> ())
      ~startup_timeout:0.0 ()
  in
  let tool = Diagnostics.tool ~clock ~dune () in
  let call = decode_call tool ~name:Diagnostics.name in
  Tool.Call.run call () |> print_status_kind;
  Tool.Call.run call () |> print_status_kind;
  Printf.printf "starts: %d\n" !starts;
  [%expect
    {|
    status: failed unavailable
    status: failed unavailable
    starts: 0 |}]

let%expect_test "a stopped Dune starter cannot run later" =
  Eio_main.run @@ fun stdenv ->
  Eio.Time.sleep (Eio.Stdenv.clock stdenv) 0.0;
  let starts = ref 0 in
  let start =
    Spice_ocaml_dune.Rpc.Instance.Start.make (fun () ->
        incr starts;
        Ok ())
  in
  Spice_ocaml_dune.Rpc.Instance.Start.stop start;
  Spice_ocaml_dune.Rpc.Instance.Start.stop start;
  Printf.printf "run refused: %b\n"
    (Result.is_error (Spice_ocaml_dune.Rpc.Instance.Start.run start));
  Printf.printf "starts: %d\n" !starts;
  [%expect
    {|
    run refused: true
    starts: 0 |}]

(* ------------------------------------------------------------------ *)
(* Project_source: fresh-or-snapshot logic with injected fakes         *)
(* ------------------------------------------------------------------ *)

module Project_source = Dune.Project_source
module Ocaml = Spice_ocaml

let fake_project label = Ocaml.Project.make ~build_context:label []

let lock_error =
  Dune.Error.Command_failed
    {
      argv = [ "dune"; "describe"; "workspace" ];
      cwd = ".";
      status = Some 1;
      stderr =
        "Error: A running dune (pid 4321) instance has locked the build \
         directory. Refusing to proceed.";
    }

let genuine_error =
  Dune.Error.Command_failed
    {
      argv = [ "dune"; "describe"; "workspace" ];
      cwd = ".";
      status = Some 1;
      stderr = "Error: No dune-project file found in this directory.";
    }

let print_freshness = function
  | Project_source.Freshness.Fresh -> print_endline "fresh"
  | Project_source.Freshness.Snapshot { captured_at; drifted; endpoint } ->
      Printf.printf "snapshot captured_at=%.0f drifted=%b endpoint=%s\n"
        captured_at drifted
        (Option.value ~default:"<none>" endpoint)

let print_get = function
  | Ok (project, freshness) ->
      Printf.printf "ok build_context=%s freshness="
        (Option.value ~default:"<none>" (Ocaml.Project.build_context project));
      print_freshness freshness
  | Error (Project_source.Blocked_by_watch { endpoint }) ->
      Printf.printf "blocked endpoint=%s\n"
        (Option.value ~default:"<none>" endpoint)
  | Error (Project_source.Describe_error error) ->
      Printf.printf "describe_error: %s\n" (Dune.Error.message error)

let make_source ?(now = fun () -> 1000.0) ~status ~describe () =
  Project_source.create ~refresh_status:status ~describe ~now ()

let%expect_test
    "project_source serves the boot snapshot under a watch with no doomed \
     describe" =
  let describe_calls = ref 0 in
  let describe ~cancelled:_ =
    incr describe_calls;
    Ok (fake_project "boot-shape")
  in
  let source =
    make_source
      ~status:(fun () -> Project_source.Watch_endpoint "dune-rpc:42")
      ~describe ()
  in
  (match Project_source.capture source with
  | Ok () -> print_endline "capture: ok"
  | Error _ -> print_endline "capture: error");
  Project_source.get source () |> print_get;
  Printf.printf "describe_calls=%d\n" !describe_calls;
  [%expect
    {|
    capture: ok
    ok build_context=boot-shape freshness=snapshot captured_at=1000 drifted=false endpoint=dune-rpc:42
    describe_calls=1 |}]

let%expect_test
    "project_source runs a fresh describe when no watch is registered and \
     snapshots it" =
  let status = ref Project_source.No_watch in
  let describe ~cancelled:_ = Ok (fake_project "fresh-shape") in
  let source = make_source ~status:(fun () -> !status) ~describe () in
  Project_source.get source () |> print_get;
  status := Project_source.Watch_endpoint "dune-rpc:7";
  Project_source.get source () |> print_get;
  [%expect
    {|
    ok build_context=fresh-shape freshness=fresh
    ok build_context=fresh-shape freshness=snapshot captured_at=1000 drifted=false endpoint=dune-rpc:7 |}]

let%expect_test "project_source serves the snapshot on a non-RPC lock error" =
  let phase = ref `Boot in
  let describe ~cancelled:_ =
    match !phase with
    | `Boot -> Ok (fake_project "boot-shape")
    | `Locked -> Error lock_error
  in
  let source =
    make_source ~status:(fun () -> Project_source.No_watch) ~describe ()
  in
  (match Project_source.capture source with
  | Ok () -> ()
  | Error _ -> print_endline "capture failed");
  phase := `Locked;
  Project_source.get source () |> print_get;
  [%expect
    {| ok build_context=boot-shape freshness=snapshot captured_at=1000 drifted=false endpoint=<none> |}]

let%expect_test
    "project_source blocks or surfaces genuine errors without a snapshot" =
  print_endline "-- watch, no snapshot --";
  make_source
    ~status:(fun () -> Project_source.Watch_endpoint "dune-rpc:9")
    ~describe:(fun ~cancelled:_ -> Error lock_error)
    ()
  |> fun source ->
  Project_source.get source () |> print_get;
  print_endline "-- non-rpc lock, no snapshot --";
  make_source
    ~status:(fun () -> Project_source.No_watch)
    ~describe:(fun ~cancelled:_ -> Error lock_error)
    ()
  |> fun source ->
  Project_source.get source () |> print_get;
  print_endline "-- genuine describe error --";
  make_source
    ~status:(fun () -> Project_source.No_watch)
    ~describe:(fun ~cancelled:_ -> Error genuine_error)
    ()
  |> fun source ->
  Project_source.get source () |> print_get;
  [%expect
    {|
    -- watch, no snapshot --
    blocked endpoint=dune-rpc:9
    -- non-rpc lock, no snapshot --
    blocked endpoint=<none>
    -- genuine describe error --
    describe_error: command dune describe workspace in . exited 1: Error: No dune-project file found in this directory. |}]

let%expect_test
    "project_source reflects the host drift flag and a fresh describe clears it"
    =
  let status = ref Project_source.No_watch in
  let describe ~cancelled:_ = Ok (fake_project "shape") in
  let source = make_source ~status:(fun () -> !status) ~describe () in
  (match Project_source.capture source with Ok () -> () | Error _ -> ());
  Project_source.set_drifted source true;
  status := Project_source.Watch_endpoint "dune-rpc:1";
  Project_source.get source () |> print_get;
  status := Project_source.No_watch;
  Project_source.get source () |> print_get;
  status := Project_source.Watch_endpoint "dune-rpc:1";
  Project_source.get source () |> print_get;
  [%expect
    {|
    ok build_context=shape freshness=snapshot captured_at=1000 drifted=true endpoint=dune-rpc:1
    ok build_context=shape freshness=fresh
    ok build_context=shape freshness=snapshot captured_at=1000 drifted=false endpoint=dune-rpc:1 |}]

let%expect_test "project_source capture failure leaves no snapshot" =
  let status = ref Project_source.No_watch in
  let source =
    make_source
      ~status:(fun () -> !status)
      ~describe:(fun ~cancelled:_ -> Error genuine_error)
      ()
  in
  (match Project_source.capture source with
  | Ok () -> print_endline "capture: ok"
  | Error error ->
      Printf.printf "capture: error %s\n" (Dune.Error.message error));
  (* A later Watch_endpoint with no snapshot must block. *)
  status := Project_source.Watch_endpoint "dune-rpc:2";
  Project_source.get source () |> print_get;
  [%expect
    {|
    capture: error command dune describe workspace in . exited 1: Error: No dune-project file found in this directory.
    blocked endpoint=dune-rpc:2 |}]

(* ------------------------------------------------------------------ *)
(* ocaml_dune_describe: freshness projection through a project_source  *)
(* ------------------------------------------------------------------ *)

let run_describe_source ~process_mgr ~clock ~cwd ~workspace source =
  let tool =
    Describe.tool ~sandbox ~process_mgr ~clock ~cwd ~workspace
      ~project_source:source ()
  in
  let call = decode_call tool ~name:Describe.name in
  let result = Tool.Call.run call () in
  print_status result;
  match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output ->
      String.split_on_char '\n' (Tool.Output.text output)
      |> List.iter (fun line ->
          if String.starts_with ~prefix:"freshness:" line then
            print_endline line)

let%expect_test "ocaml_dune_describe stamps fresh freshness evidence" =
  with_project_clock @@ fun ~root ~process_mgr ~clock ~cwd ~workspace ->
  ignore root;
  let source =
    make_source
      ~status:(fun () -> Project_source.No_watch)
      ~describe:(fun ~cancelled:_ -> Ok (fake_project "session-shape"))
      ()
  in
  run_describe_source ~process_mgr ~clock ~cwd ~workspace source;
  [%expect {|
    status: completed
    freshness: fresh |}]

let%expect_test "ocaml_dune_describe stamps snapshot freshness under a watch" =
  with_project_clock @@ fun ~root ~process_mgr ~clock ~cwd ~workspace ->
  ignore root;
  let source =
    make_source
      ~status:(fun () -> Project_source.Watch_endpoint "dune-rpc:5")
      ~describe:(fun ~cancelled:_ -> Ok (fake_project "boot-shape"))
      ()
  in
  (match Project_source.capture source with Ok () -> () | Error _ -> ());
  run_describe_source ~process_mgr ~clock ~cwd ~workspace source;
  [%expect
    {|
    status: completed
    freshness: snapshot captured_at=1000 drifted=false endpoint=dune-rpc:5 |}]

let%expect_test
    "ocaml_dune_describe reports unavailable when blocked with no snapshot" =
  with_project_clock @@ fun ~root ~process_mgr ~clock ~cwd ~workspace ->
  ignore root;
  let source =
    make_source
      ~status:(fun () -> Project_source.Watch_endpoint "dune-rpc:5")
      ~describe:(fun ~cancelled:_ -> Error lock_error)
      ()
  in
  let tool =
    Describe.tool ~sandbox ~process_mgr ~clock ~cwd ~workspace
      ~project_source:source ()
  in
  Tool.Call.run (decode_call tool ~name:Describe.name) () |> print_status_kind;
  [%expect {| status: failed unavailable |}]

[%%run_tests "spice.tools.ocaml_dune.expect"]
