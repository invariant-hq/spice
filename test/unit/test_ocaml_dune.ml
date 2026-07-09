(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Dune = Spice_ocaml_dune
module Ocaml = Spice_ocaml

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %s" msg (Dune.Error.message error)

let workspace () =
  let root =
    Spice_workspace.Root.make (Spice_path.Abs.of_string_exn "/workspace")
  in
  Spice_workspace.single root

let workspace_output =
  {|
((root /workspace)
 (build_context _build/default)
 (library
  ((name foo)
   (uid uid-foo)
   (local true)
   (requires (uid-unix))
   (source_dir lib)
   (modules
    (((name Foo)
      (impl lib/foo.ml)
      (intf lib/foo.mli)
      (cmt ())
      (cmti ())
      (module_deps ((for_intf (Bar)) (for_impl (Baz)))))))
   (include_dirs (_build/default/lib))))
 (library
  ((name unix)
   (uid uid-unix)
   (local false)
   (requires ())
   (source_dir /outside/toolchain/lib/unix)
   (modules
    (((name Unix)
      (impl /outside/toolchain/lib/unix/unix.ml)
      (intf ())
      (cmt ())
      (cmti ()))))
   (include_dirs ())))
 (executables
  ((names (main))
   (requires (uid-foo))
   (modules
    (((name Main)
      (impl bin/main.ml)
      (intf ())
      (cmt ())
      (cmti ())
      (module_deps ((for_intf ()) (for_impl (Foo)))))))
   (include_dirs (_build/default/bin)))))
|}

let tests_output =
  {|
(((name foo_tests)
  (source_dir lib)
  (package ())
  (enabled true)
  (location lib/dune:1:0)
  (target @lib/runtest)))
|}

let describe_outputs_normalize_project () =
  let workspace = workspace () in
  let project =
    Dune.Describe.of_outputs ~workspace ~workspace_output ~tests_output
    |> expect_ok "describe outputs"
  in
  equal int ~msg:"components" 3 (List.length (Ocaml.Project.components project));
  equal int ~msg:"tests" 1 (List.length (Ocaml.Project.tests project));
  let external_component =
    Ocaml.Project.components project
    |> List.find_opt (fun component ->
        String.equal (Ocaml.Project.Component.name component) "unix")
  in
  let external_component =
    match external_component with
    | Some component -> component
    | None -> failf "missing external library component"
  in
  equal (option string) ~msg:"external source dir" None
    (Option.map Spice_workspace.Path.display
       (Ocaml.Project.Component.source_dir external_component));
  begin match Ocaml.Project.Component.units external_component with
  | [ unit_ ] ->
      equal (option string) ~msg:"external unit impl" None
        (Option.map Spice_workspace.Path.display
           (Ocaml.Project.Compilation_unit.impl unit_))
  | units -> failf "unexpected external unit count %d" (List.length units)
  end;
  begin match Ocaml.Project.build_context project with
  | Some "_build/default" -> ()
  | Some build_context -> failf "unexpected build context %s" build_context
  | None -> failf "missing build context"
  end;
  let lib_id = Ocaml.Project.Component.Id.library "foo" in
  begin match Ocaml.Project.dependencies project lib_id with
  | Some (Ocaml.Project.Deps.Known [ dep ]) ->
      equal string ~msg:"library dependency" "unix"
        (Ocaml.Project.Component.name dep)
  | None | Some (Ocaml.Project.Deps.Unknown | Ocaml.Project.Deps.Known _) ->
      failf "unexpected library dependencies"
  end;
  let exe_id =
    Ocaml.Project.Component.Id.executable
      ~dir:
        (Spice_workspace.Path.make
           ~root:(List.hd (Spice_workspace.roots workspace))
           (Spice_path.Rel.of_string_exn "bin"))
      ~name:"main"
  in
  begin match Ocaml.Project.dependencies project exe_id with
  | Some (Ocaml.Project.Deps.Known [ dep ]) ->
      equal string ~msg:"executable dependency" "foo"
        (Ocaml.Project.Component.name dep)
  | None | Some (Ocaml.Project.Deps.Unknown | Ocaml.Project.Deps.Known _) ->
      failf "unexpected executable dependencies"
  end;
  let test = List.hd (Ocaml.Project.tests project) in
  equal string ~msg:"test target" "@lib/runtest"
    (Ocaml.Project.Test.target test);
  equal (option string) ~msg:"test component" (Some "library:foo")
    (Option.map Ocaml.Project.Component.Id.to_string
       (Ocaml.Project.Test.component test))

let malformed_workspace_data_returns_parse_error () =
  let workspace = workspace () in
  let output =
    {|
((root /workspace)
 (library
  ((name "")
   (uid uid-empty)
   (local true)
   (requires ())
   (source_dir lib)
   (modules ()))))
|}
  in
  match Dune.Describe.of_workspace_output ~workspace output with
  | Error (Dune.Error.Parse_error { source = Dune.Error.Workspace_describe; _ })
    ->
      ()
  | Error error -> failf "unexpected error: %s" (Dune.Error.message error)
  | Ok _ -> failf "expected malformed workspace data to fail"

let malformed_module_name_returns_parse_error () =
  let workspace = workspace () in
  let output =
    {|
((root /workspace)
 (library
  ((name foo)
   (uid uid-foo)
   (local true)
   (requires ())
   (source_dir lib)
   (modules
    (((name lowercase)
      (impl lib/foo.ml)
      (intf ())
      (cmt ())
      (cmti ())))))))
|}
  in
  match Dune.Describe.of_workspace_output ~workspace output with
  | Error (Dune.Error.Parse_error { source = Dune.Error.Workspace_describe; _ })
    ->
      ()
  | Error error -> failf "unexpected error: %s" (Dune.Error.message error)
  | Ok _ -> failf "expected malformed module name to fail"

let malformed_tests_data_returns_parse_error () =
  let workspace = workspace () in
  let project =
    Dune.Describe.of_workspace_output ~workspace workspace_output
    |> expect_ok "describe workspace output"
  in
  let output =
    {|
(((name "")
  (source_dir lib)
  (package ())
  (enabled true)
  (location lib/dune:1:0)
  (target @lib/runtest)))
|}
  in
  match Dune.Describe.of_tests_output ~workspace project output with
  | Error (Dune.Error.Parse_error { source = Dune.Error.Tests_describe; _ }) ->
      ()
  | Error error -> failf "unexpected error: %s" (Dune.Error.message error)
  | Ok _ -> failf "expected malformed tests data to fail"

let rpc_diagnostic_store_tracks_events () =
  let diagnostic =
    Ocaml.Diagnostic.make ~source:Ocaml.Diagnostic.Source.dune
      ~severity:Ocaml.Diagnostic.Severity.Error "build failed"
  in
  let id = Dune.Rpc.Diagnostic.Id.of_string "1" in
  let store =
    Dune.Rpc.Diagnostic.Store.empty
    |> Dune.Rpc.Diagnostic.Store.apply
         (Dune.Rpc.Diagnostic.Add (id, diagnostic))
  in
  equal int ~msg:"diagnostics" 1
    (List.length (Dune.Rpc.Diagnostic.Store.to_list store));
  begin match Dune.Rpc.Diagnostic.Store.find id store with
  | Some found ->
      equal string ~msg:"diagnostic message" "build failed"
        (Ocaml.Diagnostic.message found)
  | None -> failf "missing diagnostic"
  end;
  let store =
    Dune.Rpc.Diagnostic.Store.apply (Dune.Rpc.Diagnostic.Remove id) store
  in
  equal int ~msg:"diagnostics removed" 0
    (List.length (Dune.Rpc.Diagnostic.Store.to_list store))

let diagnostic message =
  Ocaml.Diagnostic.make ~source:Ocaml.Diagnostic.Source.dune
    ~severity:Ocaml.Diagnostic.Severity.Error message

let rpc_diagnostic_store_apply_many_and_clear () =
  let a = Dune.Rpc.Diagnostic.Id.of_string "a" in
  let b = Dune.Rpc.Diagnostic.Id.of_string "b" in
  let store =
    Dune.Rpc.Diagnostic.Store.apply_many
      [
        Dune.Rpc.Diagnostic.Add (a, diagnostic "first");
        Dune.Rpc.Diagnostic.Add (b, diagnostic "second");
      ]
      Dune.Rpc.Diagnostic.Store.empty
  in
  equal int ~msg:"both applied" 2
    (List.length (Dune.Rpc.Diagnostic.Store.to_list store));
  (* Add on an existing id replaces the diagnostic in place. *)
  let store =
    Dune.Rpc.Diagnostic.Store.apply
      (Dune.Rpc.Diagnostic.Add (a, diagnostic "replaced"))
      store
  in
  equal int ~msg:"replace does not grow the set" 2
    (List.length (Dune.Rpc.Diagnostic.Store.to_list store));
  (match Dune.Rpc.Diagnostic.Store.find a store with
  | Some found ->
      equal string ~msg:"replaced message wins" "replaced"
        (Ocaml.Diagnostic.message found)
  | None -> failf "replaced diagnostic missing");
  (* Removing an absent id is a no-op; find of an absent id is None. *)
  let store =
    Dune.Rpc.Diagnostic.Store.apply
      (Dune.Rpc.Diagnostic.Remove (Dune.Rpc.Diagnostic.Id.of_string "absent"))
      store
  in
  equal int ~msg:"remove absent is a no-op" 2
    (List.length (Dune.Rpc.Diagnostic.Store.to_list store));
  equal (option string) ~msg:"find absent is None" None
    (Option.map Ocaml.Diagnostic.message
       (Dune.Rpc.Diagnostic.Store.find
          (Dune.Rpc.Diagnostic.Id.of_string "absent")
          store));
  let store = Dune.Rpc.Diagnostic.Store.clear store in
  equal int ~msg:"clear empties the set" 0
    (List.length (Dune.Rpc.Diagnostic.Store.to_list store))

let rpc_diagnostic_id () =
  let a = Dune.Rpc.Diagnostic.Id.of_string "id-1" in
  equal string ~msg:"id round-trips" "id-1" (Dune.Rpc.Diagnostic.Id.to_string a);
  is_true ~msg:"equal ids compare equal"
    (Dune.Rpc.Diagnostic.Id.equal a (Dune.Rpc.Diagnostic.Id.of_string "id-1"));
  is_true ~msg:"distinct ids order"
    (Dune.Rpc.Diagnostic.Id.compare a (Dune.Rpc.Diagnostic.Id.of_string "id-2")
    < 0);
  raises_match ~msg:"empty id rejected"
    (function Invalid_argument _ -> true | _ -> false)
    (fun () -> ignore (Dune.Rpc.Diagnostic.Id.of_string ""))

let rpc_build_progress_running () =
  is_true ~msg:"empty build is waiting"
    (match Dune.Rpc.Build.progress Dune.Rpc.Build.empty with
    | Dune.Rpc.Build.Waiting -> true
    | _ -> false);
  is_true ~msg:"waiting counts as running"
    (Dune.Rpc.Build.running Dune.Rpc.Build.empty);
  let in_progress =
    Dune.Rpc.Build.update
      (Dune.Rpc.Build.In_progress { complete = 1; remaining = 2; failed = 0 })
      Dune.Rpc.Build.empty
  in
  is_true ~msg:"in-progress is running" (Dune.Rpc.Build.running in_progress);
  List.iter
    (fun (label, progress) ->
      is_true
        ~msg:(label ^ " is not running")
        (not
           (Dune.Rpc.Build.running
              (Dune.Rpc.Build.update progress Dune.Rpc.Build.empty))))
    [
      ("success", Dune.Rpc.Build.Success);
      ("failed", Dune.Rpc.Build.Failed);
      ("interrupted", Dune.Rpc.Build.Interrupted);
    ]

let () =
  run "spice.ocaml_dune"
    [
      test "describe outputs normalize project"
        describe_outputs_normalize_project;
      test "malformed workspace data returns parse error"
        malformed_workspace_data_returns_parse_error;
      test "malformed module name returns parse error"
        malformed_module_name_returns_parse_error;
      test "malformed tests data returns parse error"
        malformed_tests_data_returns_parse_error;
      test "rpc diagnostic store tracks events"
        rpc_diagnostic_store_tracks_events;
      test "rpc diagnostic store apply_many, replace, and clear"
        rpc_diagnostic_store_apply_many_and_clear;
      test "rpc diagnostic id round-trips and validates" rpc_diagnostic_id;
      test "rpc build progress running predicate" rpc_build_progress_running;
    ]
