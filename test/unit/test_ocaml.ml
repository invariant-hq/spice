(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Ocaml = Spice_ocaml

let expect_invalid_arg msg f =
  match f () with
  | _ -> failf "%s: expected Invalid_argument" msg
  | exception Invalid_argument _ -> ()

let position_and_range () =
  let p1 = Ocaml.Position.make ~line:1 ~column:0 in
  let p2 = Ocaml.Position.make ~line:3 ~column:4 in
  let range = Ocaml.Range.make ~start:p1 ~end_:p2 in
  let same_start = Ocaml.Range.make ~start:p1 ~end_:p1 in
  let root =
    Spice_workspace.Root.make (Spice_path.Abs.of_string_exn "/workspace")
  in
  let path =
    Spice_workspace.Path.make ~root
      (Spice_path.Rel.of_string_exn "lib/example.ml")
  in
  let location = Ocaml.Location.make ~path ~range in
  equal int ~msg:"line" 1 (Ocaml.Position.line p1);
  equal int ~msg:"column" 4 (Ocaml.Position.column p2);
  is_true ~msg:"location start"
    (Ocaml.Position.equal p1 (Ocaml.Location.start location));
  is_true ~msg:"location end"
    (Ocaml.Position.equal p2 (Ocaml.Location.end_ location));
  is_true ~msg:"range order" (Ocaml.Range.compare same_start range < 0);
  is_true ~msg:"range contains child"
    (Ocaml.Range.contains ~outer:range same_start);
  expect_invalid_arg "line lower bound" (fun () ->
      Ocaml.Position.make ~line:0 ~column:0);
  expect_invalid_arg "column lower bound" (fun () ->
      Ocaml.Position.make ~line:1 ~column:(-1));
  expect_invalid_arg "range order" (fun () ->
      Ocaml.Range.make ~start:p2 ~end_:p1)

let diagnostic_invariants () =
  let source = Ocaml.Diagnostic.Source.other "ppx-driver" in
  let diagnostic =
    Ocaml.Diagnostic.make ~source ~severity:Ocaml.Diagnostic.Severity.Warning
      ~code:"32"
      ~tags:[ Ocaml.Diagnostic.Tag.Unnecessary ]
      "unused value"
  in
  equal string ~msg:"source string" "ppx-driver"
    (Ocaml.Diagnostic.Source.to_string (Ocaml.Diagnostic.source diagnostic));
  equal (option string) ~msg:"code" (Some "32")
    (Ocaml.Diagnostic.code diagnostic);
  expect_invalid_arg "empty diagnostic message" (fun () ->
      Ocaml.Diagnostic.make ~source:Ocaml.Diagnostic.Source.merlin
        ~severity:Ocaml.Diagnostic.Severity.Error "");
  expect_invalid_arg "duplicate tags" (fun () ->
      Ocaml.Diagnostic.make ~source:Ocaml.Diagnostic.Source.merlin
        ~severity:Ocaml.Diagnostic.Severity.Warning
        ~tags:
          [ Ocaml.Diagnostic.Tag.Deprecated; Ocaml.Diagnostic.Tag.Deprecated ]
        "deprecated value");
  expect_invalid_arg "bad source label" (fun () ->
      ignore (Ocaml.Diagnostic.Source.other "Bad_Source"));
  expect_invalid_arg "reserved source label" (fun () ->
      ignore (Ocaml.Diagnostic.Source.other "dune"));
  begin match Ocaml.Diagnostic.Source.other "ppx-driver" with
  | Ocaml.Diagnostic.Source.Other "ppx-driver" -> ()
  | source ->
      failf "unexpected other source %s"
        (Ocaml.Diagnostic.Source.to_string source)
  end;
  let related =
    Ocaml.Diagnostic.Related.make "in expansion of generated code"
  in
  let diagnostic_with_related =
    Ocaml.Diagnostic.make ~source ~severity:Ocaml.Diagnostic.Severity.Warning
      ~code:"32"
      ~tags:[ Ocaml.Diagnostic.Tag.Unnecessary ]
      ~related:[ related ] "unused value"
  in
  is_true ~msg:"diagnostic compare distinguishes related information"
    (Ocaml.Diagnostic.compare diagnostic diagnostic_with_related < 0);
  is_true ~msg:"diagnostic compare matches equality"
    (Ocaml.Diagnostic.compare diagnostic diagnostic = 0);
  is_true ~msg:"diagnostic severity order"
    (Ocaml.Diagnostic.Severity.compare Ocaml.Diagnostic.Severity.Error
       Ocaml.Diagnostic.Severity.Warning
    < 0);
  is_true ~msg:"diagnostic tag order"
    (Ocaml.Diagnostic.Tag.compare Ocaml.Diagnostic.Tag.Unnecessary
       Ocaml.Diagnostic.Tag.Deprecated
    < 0)

let project_description_invariants () =
  let root =
    Spice_workspace.Root.make (Spice_path.Abs.of_string_exn "/workspace")
  in
  let path rel =
    Spice_workspace.Path.make ~root (Spice_path.Rel.of_string_exn rel)
  in
  let foo = Ocaml.Module_name.make "Foo" in
  let bar = Ocaml.Module_name.make "Bar" in
  let baz = Ocaml.Module_name.make "Baz" in
  let unit_ =
    Ocaml.Project.Compilation_unit.make ~impl:(path "lib/foo.ml")
      ~intf:(path "lib/foo.mli")
      ~interface_deps:(Ocaml.Project.Deps.known [ bar ])
      ~implementation_deps:(Ocaml.Project.Deps.known [ baz ])
      foo
  in
  let lib_id = Ocaml.Project.Component.Id.library "foo" in
  let ext_id = Ocaml.Project.Component.Id.external_library "unix" in
  let exe_id =
    Ocaml.Project.Component.Id.executable ~dir:(path "bin") ~name:"main"
  in
  equal string ~msg:"executable id uses logical workspace path"
    "executable:/workspace/bin:main"
    (Ocaml.Project.Component.Id.to_string exe_id);
  let external_dep = Ocaml.Project.Component.external_library ~name:"unix" () in
  let library =
    Ocaml.Project.Component.local_library ~name:"foo" ~source_dir:(path "lib")
      ~units:[ unit_ ]
      ~requires:(Ocaml.Project.Deps.known [ ext_id ])
      ()
  in
  let executable =
    Ocaml.Project.Component.executable ~dir:(path "bin") ~name:"main"
      ~requires:Ocaml.Project.Deps.unknown ()
  in
  let resolved_executable =
    Ocaml.Project.Component.with_requires
      (Ocaml.Project.Deps.known [ lib_id ])
      executable
  in
  equal string ~msg:"library id"
    (Ocaml.Project.Component.Id.to_string lib_id)
    (Ocaml.Project.Component.id library |> Ocaml.Project.Component.Id.to_string);
  equal string ~msg:"external id"
    (Ocaml.Project.Component.Id.to_string ext_id)
    (Ocaml.Project.Component.id external_dep
    |> Ocaml.Project.Component.Id.to_string);
  equal string ~msg:"executable id"
    (Ocaml.Project.Component.Id.to_string exe_id)
    (Ocaml.Project.Component.id executable
    |> Ocaml.Project.Component.Id.to_string);
  begin match Ocaml.Project.Component.requires resolved_executable with
  | Ocaml.Project.Deps.Known [ id ] ->
      equal string ~msg:"with_requires"
        (Ocaml.Project.Component.Id.to_string lib_id)
        (Ocaml.Project.Component.Id.to_string id)
  | Ocaml.Project.Deps.Unknown | Ocaml.Project.Deps.Known _ ->
      failf "unexpected with_requires result"
  end;
  let test =
    Ocaml.Project.Test.make ~component:lib_id ~name:"foo_tests"
      ~source_dir:(path "test") ~target:"@test/runtest" ~enabled:true ()
  in
  let project =
    Ocaml.Project.make ~root:(path ".") ~build_context:"default" ~tests:[ test ]
      [ library; external_dep; executable ]
  in
  equal int ~msg:"components" 3 (List.length (Ocaml.Project.components project));
  equal int ~msg:"tests" 1 (List.length (Ocaml.Project.tests project));
  begin match Ocaml.Project.dependencies project lib_id with
  | Some (Ocaml.Project.Deps.Known [ dep ]) ->
      equal string ~msg:"library dependency" "unix"
        (Ocaml.Project.Component.name dep)
  | None | Some (Ocaml.Project.Deps.Unknown | Ocaml.Project.Deps.Known _) ->
      failf "unexpected known dependency result"
  end;
  begin match Ocaml.Project.dependencies project exe_id with
  | Some Ocaml.Project.Deps.Unknown -> ()
  | None | Some (Ocaml.Project.Deps.Known _) ->
      failf "executable deps should be unknown"
  end;
  begin match
    Ocaml.Project.dependencies project
      (Ocaml.Project.Component.Id.library "missing")
  with
  | None -> ()
  | Some _ -> failf "missing component dependencies should be None"
  end;
  equal int ~msg:"local components" 2
    (List.length (Ocaml.Project.local_components project));
  equal int ~msg:"external components" 1
    (List.length (Ocaml.Project.external_components project));
  expect_invalid_arg "duplicate component ids" (fun () ->
      Ocaml.Project.make [ library; library ]);
  expect_invalid_arg "duplicate dependency ids" (fun () ->
      Ocaml.Project.Component.executable ~dir:(path "bad") ~name:"bad"
        ~requires:(Ocaml.Project.Deps.known [ ext_id; ext_id ])
        ());
  expect_invalid_arg "empty module dependency" (fun () ->
      ignore (Ocaml.Module_name.make ""));
  List.iter
    (fun name ->
      expect_invalid_arg ("invalid module name " ^ name) (fun () ->
          ignore (Ocaml.Module_name.make name)))
    [ "foo"; "Foo.Bar"; "Foo-bar"; " Foo"; "Foo\000Bar" ];
  expect_invalid_arg "empty test target" (fun () ->
      Ocaml.Project.Test.make ~name:"bad" ~source_dir:(path "test") ~target:""
        ~enabled:true ());
  expect_invalid_arg "unknown required component" (fun () ->
      let bad =
        Ocaml.Project.Component.executable ~dir:(path "bad") ~name:"bad"
          ~requires:
            (Ocaml.Project.Deps.known
               [ Ocaml.Project.Component.Id.external_library "missing" ])
          ()
      in
      Ocaml.Project.make [ bad ]);
  expect_invalid_arg "test references unknown component" (fun () ->
      let bad_test =
        Ocaml.Project.Test.make
          ~component:(Ocaml.Project.Component.Id.library "missing")
          ~name:"bad" ~source_dir:(path "test") ~target:"@bad" ~enabled:true ()
      in
      Ocaml.Project.make ~tests:[ bad_test ] [ library; external_dep ])

let () =
  run "spice.ocaml"
    [
      test "position and range" position_and_range;
      test "diagnostic invariants" diagnostic_invariants;
      test "project description invariants" project_description_invariants;
    ]
