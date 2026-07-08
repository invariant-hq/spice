(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Syntax = Spice_path
module Workspace = Spice_workspace

let syntax_error = testable ~pp:Syntax.Error.pp ~equal:Syntax.Error.equal ()
let error = testable ~pp:Workspace.Error.pp ~equal:Workspace.Error.equal ()

let resolve_error =
  testable ~pp:Workspace.Resolve_error.pp ~equal:Workspace.Resolve_error.equal
    ()

let root_value = testable ~pp:Workspace.Root.pp ~equal:Workspace.Root.equal ()
let path_value = testable ~pp:Workspace.Path.pp ~equal:Workspace.Path.equal ()
let workspace_value = testable ~pp:Workspace.pp ~equal:Workspace.equal ()

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %s" msg (Workspace.Error.message error)

let abs text =
  match Syntax.Abs.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Syntax.Error.pp error

let rel text =
  match Syntax.Rel.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Syntax.Error.pp error

let make_root text = Workspace.Root.make (abs text)
let make_path root text = Workspace.Path.make ~root (rel text)
let make_workspace roots = expect_ok "workspace" (Workspace.make roots)
let path_string path = Workspace.Path.to_string path

let root_values_compare_and_collect () =
  let a = make_root "/workspace/./root" in
  let b = make_root "/workspace/root" in
  let c = make_root "/workspace/other" in
  let keyed = Workspace.Root.make ~key:"workspace-root" (abs "/tmp/root") in
  let same_key =
    Workspace.Root.make ~key:"workspace-root" (abs "/other/root")
  in
  equal string ~msg:"default key is normalized directory" "/workspace/root"
    (Workspace.Root.key a);
  is_true ~msg:"equal uses stable key and directory" (Workspace.Root.equal a b);
  is_true ~msg:"same_key compares root identity"
    (Workspace.Root.same_key keyed same_key);
  is_true ~msg:"same key with different dir is not equal"
    (not (Workspace.Root.equal keyed same_key));
  equal int ~msg:"compare agrees with equal" 0 (Workspace.Root.compare a b);
  is_true ~msg:"distinct roots are distinct" (not (Workspace.Root.equal a c))

let path_projects_and_composes () =
  let root = make_root "/workspace" in
  let root_path = make_path root "." in
  let file = make_path root "src/a.ml" in
  equal root_value ~msg:"root accessor" root (Workspace.Path.root file);
  equal string ~msg:"relative accessor" "src/a.ml"
    (Syntax.Rel.to_string (Workspace.Path.rel file));
  equal string ~msg:"absolute projection" "/workspace/src/a.ml"
    (Syntax.Abs.to_string (Workspace.Path.abs file));
  is_true ~msg:"root path is recognized" (Workspace.Path.is_root root_path);
  equal (option string) ~msg:"root path has no basename" None
    (Workspace.Path.basename root_path);
  equal (option path_value) ~msg:"root path has no parent" None
    (Workspace.Path.parent root_path);
  equal (option string) ~msg:"basename" (Some "a.ml")
    (Workspace.Path.basename file);
  equal (option string) ~msg:"parent" (Some "/workspace/src")
    (Option.map path_string (Workspace.Path.parent file));
  equal string ~msg:"display is root-relative" "src/a.ml"
    (Workspace.Path.display file);
  equal string ~msg:"root display is dot" "." (Workspace.Path.display root_path);
  equal
    (result string syntax_error)
    ~msg:"add_component appends one component" (Ok "/workspace/src/a.ml")
    (Result.map path_string
       (Workspace.Path.add_component (make_path root "src") "a.ml"));
  equal
    (result string syntax_error)
    ~msg:"add_component rejects malformed components"
    (Error (Syntax.Error.Malformed_component "a/b"))
    (Result.map path_string (Workspace.Path.add_component root_path "a/b"));
  equal (option string) ~msg:"relativize returns suffix" (Some "a.ml")
    (Option.map Syntax.Rel.to_string
       (Workspace.Path.relativize ~root:(make_path root "src") file));
  equal (option string) ~msg:"relativize rejects another root" None
    (Option.map Syntax.Rel.to_string
       (Workspace.Path.relativize
          ~root:(make_path (make_root "/other") ".")
          file))

let path_compares_and_collects () =
  let root = make_root "/workspace" in
  let a = make_path root "src/./a.ml" in
  let b = make_path root "src/a.ml" in
  is_true ~msg:"equal uses root and relative path" (Workspace.Path.equal a b);
  equal int ~msg:"compare agrees with equal" 0 (Workspace.Path.compare a b);
  is_true ~msg:"set membership uses path equality"
    (Workspace.Path.Set.mem b (Workspace.Path.Set.singleton a));
  equal (option string) ~msg:"map lookup uses path equality" (Some "file")
    (Workspace.Path.Map.find_opt b (Workspace.Path.Map.singleton a "file"))

let workspace_constructs_and_tracks_cwd () =
  let root_a = make_root "/workspace" in
  let root_b = make_root "/workspace/vendor" in
  let duplicate_a = make_root "/workspace/." in
  let conflicting_a =
    Workspace.Root.make ~key:(Workspace.Root.key root_a) (abs "/other-display")
  in
  let conflicting_dir_a =
    Workspace.Root.make ~key:"other-root" (Workspace.Root.dir root_a)
  in
  let unknown = make_root "/outside" in
  let workspace = make_workspace [ root_a; duplicate_a; root_b ] in
  equal (list root_value) ~msg:"make deduplicates roots in order"
    [ root_a; root_b ]
    (Workspace.roots workspace);
  equal path_value ~msg:"root_path returns first admitted root"
    (make_path root_a ".")
    (Workspace.root_path workspace);
  equal
    (result workspace_value error)
    ~msg:"same-key roots with different dirs are rejected"
    (Error
       (Workspace.Error.Conflicting_root
          { existing = root_a; duplicate = conflicting_a }))
    (Workspace.make [ root_a; conflicting_a ]);
  equal
    (result workspace_value error)
    ~msg:"same-dir roots with different keys are rejected"
    (Error
       (Workspace.Error.Conflicting_root
          { existing = root_a; duplicate = conflicting_dir_a }))
    (Workspace.make [ root_a; conflicting_dir_a ]);
  equal string ~msg:"default cwd is first root" "/workspace"
    (path_string (Workspace.cwd workspace));
  equal
    (result workspace_value error)
    ~msg:"empty roots are rejected" (Error Workspace.Error.Empty_roots)
    (Workspace.make []);
  equal
    (result workspace_value error)
    ~msg:"unknown cwd root is rejected"
    (Error (Workspace.Error.Root_not_in_workspace unknown))
    (Workspace.make ~cwd:(make_path unknown ".") [ root_a ]);
  let cwd = make_path root_b "src" in
  let workspace = expect_ok "cwd" (Workspace.with_cwd workspace cwd) in
  equal string ~msg:"with_cwd updates cwd" "/workspace/vendor/src"
    (path_string (Workspace.cwd workspace));
  equal string ~msg:"single uses relative cwd" "/workspace/app"
    (path_string (Workspace.cwd (Workspace.single ~cwd:(rel "app") root_a)))

let workspace_makes_paths_and_checks_membership () =
  let root = make_root "/workspace" in
  let nested = make_root "/workspace/vendor" in
  let outside = make_root "/outside" in
  let workspace = make_workspace [ root; nested ] in
  let path =
    expect_ok "make_path" (Workspace.make_path workspace ~root (rel "src/a.ml"))
  in
  equal string ~msg:"make_path constructs under admitted root"
    "/workspace/src/a.ml" (path_string path);
  equal (result path_value error) ~msg:"make_path rejects unknown roots"
    (Error (Workspace.Error.Root_not_in_workspace outside))
    (Workspace.make_path workspace ~root:outside (rel "src/a.ml"));
  is_true ~msg:"contains_path accepts admitted roots"
    (Workspace.contains_path workspace path);
  is_true ~msg:"contains_path rejects unknown roots"
    (not (Workspace.contains_path workspace (make_path outside "src/a.ml")));
  equal
    (result path_value resolve_error)
    ~msg:"import_abs accepts root descendants"
    (Ok (make_path root "src/a.ml"))
    (Workspace.import_abs workspace (abs "/workspace/src/a.ml"));
  equal
    (result path_value resolve_error)
    ~msg:"import_abs rejects sibling prefixes"
    (Error
       (Workspace.Resolve_error.Outside_workspace (abs "/workspace2/src/a.ml")))
    (Workspace.import_abs workspace (abs "/workspace2/src/a.ml"));
  equal
    (result path_value resolve_error)
    ~msg:"import_abs chooses most specific root"
    (Ok (make_path nested "pkg.ml"))
    (Workspace.import_abs workspace (abs "/workspace/vendor/pkg.ml"))

let workspace_converts_absolute_paths () =
  let root = make_root "/workspace" in
  let nested = make_root "/workspace/vendor" in
  let workspace = make_workspace [ root; nested ] in
  equal
    (result path_value resolve_error)
    ~msg:"import_abs chooses nested root"
    (Ok (make_path nested "pkg/a.ml"))
    (Workspace.import_abs workspace (abs "/workspace/vendor/pkg/a.ml"));
  equal
    (result path_value resolve_error)
    ~msg:"import_abs accepts root itself"
    (Ok (make_path root "."))
    (Workspace.import_abs workspace (abs "/workspace"));
  equal
    (result path_value resolve_error)
    ~msg:"import_abs rejects outside paths"
    (Error (Workspace.Resolve_error.Outside_workspace (abs "/tmp/a.ml")))
    (Workspace.import_abs workspace (abs "/tmp/a.ml"))

let workspace_uses_explicit_resolution_primitives () =
  let root = make_root "/workspace" in
  let nested = make_root "/workspace/vendor" in
  let cwd = make_path root "src/lib" in
  let workspace =
    expect_ok "workspace" (Workspace.make ~cwd [ root; nested ])
  in
  equal path_value ~msg:"Path.append appends typed relative paths below cwd"
    (make_path root "src/lib/test/a.ml")
    (Workspace.Path.append (Workspace.cwd workspace) (rel "test/a.ml"));
  equal
    (result path_value resolve_error)
    ~msg:"import_abs resolves absolute paths by most specific root"
    (Ok (make_path nested "pkg/a.ml"))
    (Workspace.import_abs workspace (abs "/workspace/vendor/pkg/a.ml"));
  equal
    (result path_value resolve_error)
    ~msg:"resolve_string interprets parent traversal"
    (Ok (make_path root "src/test/a.ml"))
    (Workspace.resolve_string workspace "../test/a.ml");
  equal
    (result path_value resolve_error)
    ~msg:"resolve_string rejects relative paths outside workspace"
    (Error (Workspace.Resolve_error.Outside_workspace (abs "/escape.ml")))
    (Workspace.resolve_string workspace "../../../escape.ml");
  equal
    (result path_value resolve_error)
    ~msg:"resolve_string rejects outside absolute paths"
    (Error (Workspace.Resolve_error.Outside_workspace (abs "/outside/a.ml")))
    (Workspace.resolve_string workspace "/outside/a.ml")

let relative_resolution_uses_most_specific_root () =
  let root = make_root "/workspace" in
  let nested = make_root "/workspace/vendor" in
  let workspace = make_workspace [ root; nested ] in
  equal
    (result path_value resolve_error)
    ~msg:"relative input entering nested root is canonicalized"
    (Ok (make_path nested "pkg.ml"))
    (Workspace.resolve_string workspace "vendor/pkg.ml");
  equal
    (result path_value resolve_error)
    ~msg:"relative and absolute input choose the same root"
    (Workspace.resolve_string workspace "/workspace/vendor/pkg.ml")
    (Workspace.resolve_string workspace "vendor/pkg.ml")

let equivalent_cwd_paths_resolve_the_same () =
  let root = make_root "/workspace" in
  let nested = make_root "/workspace/vendor" in
  let outer_cwd =
    expect_ok "outer cwd"
      (Workspace.make
         ~cwd:(Workspace.Path.make ~root (rel "vendor"))
         [ root; nested ])
  in
  let nested_cwd =
    expect_ok "nested cwd"
      (Workspace.make
         ~cwd:(Workspace.Path.make ~root:nested (rel "."))
         [ root; nested ])
  in
  let input = "../README.md" in
  let expected = Ok (make_path root "README.md") in
  equal
    (result path_value resolve_error)
    ~msg:"outer-root cwd resolves above nested directory" expected
    (Workspace.resolve_string outer_cwd input);
  equal
    (result path_value resolve_error)
    ~msg:"nested-root cwd resolves from the same logical cwd" expected
    (Workspace.resolve_string nested_cwd input)

let absolute_round_trips_through_workspace path =
  let workspace = Workspace.single (Workspace.Path.root path) in
  equal
    (result path_value resolve_error)
    ~msg:"workspace path round-trips through abs" (Ok path)
    (Workspace.import_abs workspace (Workspace.Path.abs path))

let component_gen = Gen.string_size (Gen.int_range 1 6) (Gen.char_range 'a' 'z')
let components_gen min max = Gen.list_size (Gen.int_range min max) component_gen

let rel_of_components components =
  let text = match components with [] -> "." | cs -> String.concat "/" cs in
  match Syntax.Rel.of_string text with
  | Ok rel -> rel
  | Error error -> failf "generated invalid rel: %a" Syntax.Error.pp error

let root_of_components components =
  make_root ("/" ^ String.concat "/" components)

let path_gen =
  let root_gen = components_gen 1 3 in
  let rel_gen = components_gen 0 5 in
  Gen.bind root_gen (fun root_components ->
      Gen.map
        (fun rel_components ->
          let root = make_root ("/" ^ String.concat "/" root_components) in
          let rel = rel_of_components rel_components in
          Workspace.Path.make ~root rel)
        rel_gen)

let workspace_path =
  testable ~pp:Workspace.Path.pp ~equal:Workspace.Path.equal ~gen:path_gen ()

type nested_root_case = {
  base : Workspace.Root.t;
  nested : Workspace.Root.t;
  target_abs : Syntax.Abs.t;
  target_rel : Syntax.Rel.t;
}

let pp_nested_root_case ppf case =
  Format.fprintf ppf "{ base = %a; nested = %a; target = %a }" Workspace.Root.pp
    case.base Workspace.Root.pp case.nested Syntax.Abs.pp case.target_abs

let nested_root_case_gen =
  Gen.bind (components_gen 1 3) (fun base_components ->
      Gen.bind (components_gen 1 2) (fun nested_components ->
          Gen.map
            (fun target_components ->
              let base = root_of_components base_components in
              let nested_rel = rel_of_components nested_components in
              let nested =
                Workspace.Root.make
                  (Syntax.Abs.append_rel (Workspace.Root.dir base) nested_rel)
              in
              let target_rel = rel_of_components target_components in
              let target_abs =
                Syntax.Abs.append_rel (Workspace.Root.dir nested) target_rel
              in
              { base; nested; target_abs; target_rel })
            (components_gen 0 4)))

let nested_root_case =
  testable ~pp:pp_nested_root_case ~gen:nested_root_case_gen ()

type cwd_resolve_case = {
  root : Workspace.Root.t;
  cwd : Syntax.Rel.t;
  target : Syntax.Rel.t;
}

let pp_cwd_resolve_case ppf case =
  Format.fprintf ppf "{ root = %a; cwd = %a; target = %a }" Workspace.Root.pp
    case.root Syntax.Rel.pp case.cwd Syntax.Rel.pp case.target

let cwd_resolve_case_gen =
  Gen.bind (components_gen 1 3) (fun root_components ->
      Gen.bind (components_gen 0 4) (fun cwd_components ->
          Gen.map
            (fun target_components ->
              {
                root = root_of_components root_components;
                cwd = rel_of_components cwd_components;
                target = rel_of_components target_components;
              })
            (components_gen 0 4)))

let cwd_resolve_case =
  testable ~pp:pp_cwd_resolve_case ~gen:cwd_resolve_case_gen ()

let multi_root_uses_most_specific_root case =
  let workspace = make_workspace [ case.base; case.nested ] in
  equal
    (result path_value resolve_error)
    ~msg:"import_abs uses nested generated root"
    (Ok (Workspace.Path.make ~root:case.nested case.target_rel))
    (Workspace.import_abs workspace case.target_abs)

let cwd_relative_resolve_string_reaches_target case =
  let cwd = Workspace.Path.make ~root:case.root case.cwd in
  let workspace = expect_ok "workspace" (Workspace.make ~cwd [ case.root ]) in
  let input = Syntax.Rel.reach ~from:case.cwd case.target in
  equal
    (result path_value resolve_error)
    ~msg:("resolve_string follows reach input " ^ input)
    (Ok (Workspace.Path.make ~root:case.root case.target))
    (Workspace.resolve_string workspace input)

let duplicate_roots_are_canonicalized case =
  let workspace =
    make_workspace [ case.base; case.nested; case.base; case.nested ]
  in
  equal (list root_value) ~msg:"duplicate generated roots are removed"
    [ case.base; case.nested ]
    (Workspace.roots workspace)

let import_abs_accepts_contained_paths case =
  let workspace = make_workspace [ case.base; case.nested ] in
  equal
    (result path_value resolve_error)
    ~msg:"import_abs accepts generated nested target"
    (Ok (Workspace.Path.make ~root:case.nested case.target_rel))
    (Workspace.import_abs workspace case.target_abs);
  let outside =
    abs
      (Syntax.Abs.to_string (Workspace.Root.dir case.base)
      ^ "-sibling/generated.ml")
  in
  equal
    (result path_value resolve_error)
    ~msg:"import_abs rejects generated sibling prefix"
    (Error (Workspace.Resolve_error.Outside_workspace outside))
    (Workspace.import_abs workspace outside)

let () =
  run "spice.workspace"
    [
      group "root"
        [ test "compares and collects" root_values_compare_and_collect ];
      group "path"
        [
          test "projects and composes" path_projects_and_composes;
          test "compares and collects" path_compares_and_collects;
        ];
      group "workspace"
        [
          test "constructs and tracks cwd" workspace_constructs_and_tracks_cwd;
          test "makes paths and checks membership"
            workspace_makes_paths_and_checks_membership;
          test "converts absolute paths" workspace_converts_absolute_paths;
          test "uses explicit resolution primitives"
            workspace_uses_explicit_resolution_primitives;
          test "uses most specific root for relative resolution"
            relative_resolution_uses_most_specific_root;
          test "resolves equivalent cwd paths consistently"
            equivalent_cwd_paths_resolve_the_same;
          prop' "workspace paths round-trip through abs" workspace_path
            absolute_round_trips_through_workspace;
          prop' "multi-root paths use most specific root" nested_root_case
            multi_root_uses_most_specific_root;
          prop' "cwd-relative resolve_string reaches target" cwd_resolve_case
            cwd_relative_resolve_string_reaches_target;
          prop' "duplicate roots are canonicalized" nested_root_case
            duplicate_roots_are_canonicalized;
          prop' "import_abs accepts contained paths" nested_root_case
            import_abs_accepts_contained_paths;
        ];
    ]
