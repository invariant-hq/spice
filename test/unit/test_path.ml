(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Path = Spice_path

let error = testable ~pp:Path.Error.pp ~equal:Path.Error.equal ()

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %s" msg (Path.Error.message error)

let rel text = expect_ok text (Path.Rel.of_string text)
let abs text = expect_ok text (Path.Abs.of_string text)
let rel_string path = Result.map Path.Rel.to_string (Path.Rel.of_string path)
let abs_string path = Result.map Path.Abs.to_string (Path.Abs.of_string path)

let equal_result msg expected actual =
  equal (result string error) ~msg expected actual

let component_gen = Gen.string_size (Gen.int_range 1 8) (Gen.char_range 'a' 'z')

let raw_component_gen =
  Gen.oneof
    [
      component_gen;
      Gen.oneofl [ ""; "."; ".."; "a.b"; "a-b"; "a\\b"; "a\000b"; "C:a" ];
    ]

let raw_path_input_gen =
  Gen.bind
    (Gen.list_size (Gen.int_range 0 5) raw_component_gen)
    (fun components ->
      Gen.map
        (fun prefix -> prefix ^ String.concat "/" components)
        (Gen.oneofl [ ""; "./"; "../"; "/"; "//"; "\\"; "C:" ]))

let rel_gen =
  Gen.map
    (fun components ->
      let text =
        match components with [] -> "." | cs -> String.concat "/" cs
      in
      match Path.Rel.of_string text with
      | Ok path -> path
      | Error error ->
          failf "generated invalid relative path: %a" Path.Error.pp error)
    (Gen.list_size (Gen.int_range 0 6) component_gen)

let abs_gen =
  Gen.map
    (fun components ->
      match Path.Abs.of_string ("/" ^ String.concat "/" components) with
      | Ok path -> path
      | Error error ->
          failf "generated invalid absolute path: %a" Path.Error.pp error)
    (Gen.list_size (Gen.int_range 0 6) component_gen)

let rel_path = testable ~pp:Path.Rel.pp ~equal:Path.Rel.equal ~gen:rel_gen ()
let abs_path = testable ~pp:Path.Abs.pp ~equal:Path.Abs.equal ~gen:abs_gen ()

let raw_path_input =
  testable ~pp:Format.pp_print_string ~equal:String.equal
    ~gen:raw_path_input_gen ()

let rel_parses_and_normalizes () =
  List.iter
    (fun (path, expected) -> equal_result path (Ok expected) (rel_string path))
    [
      (".", ".");
      ("a", "a");
      ("./a//b/.", "a/b");
      ("a/../b", "b");
      ("a/b/..", "a");
    ];
  equal string ~msg:"root renders as dot" "." (Path.Rel.to_string Path.Rel.root)

let rel_rejects_invalid_input () =
  List.iter
    (fun (path, expected) ->
      equal_result path (Error expected) (rel_string path))
    [
      ("", Path.Error.Empty);
      ("/a", Path.Error.Absolute);
      ("\\a", Path.Error.Absolute);
      ("C:a", Path.Error.Absolute);
      ("../a", Path.Error.Escapes_root);
      ("a/../../b", Path.Error.Escapes_root);
      ("a\\b", Path.Error.Malformed_component "a\\b");
      ("a\000b", Path.Error.Malformed_component "a\000b");
    ];
  expect_invalid_arg
    ~expected:"Spice_path.Rel.of_string_exn \"../a\": path escapes root"
    "of_string_exn rejects invalid constants" (fun () ->
      Path.Rel.of_string_exn "../a" |> Path.Rel.to_string)

let rel_components_and_accessors () =
  equal string ~msg:"root formats as dot" "." (Path.Rel.to_string Path.Rel.root);
  is_true ~msg:"root is recognized" (Path.Rel.is_root Path.Rel.root);
  equal (list string) ~msg:"root has no components" []
    (Path.Rel.components Path.Rel.root);
  equal (option string) ~msg:"root has no parent" None
    (Option.map Path.Rel.to_string (Path.Rel.parent Path.Rel.root));
  equal (option string) ~msg:"root has no basename" None
    (Path.Rel.basename Path.Rel.root);
  equal (list string) ~msg:"components expose normalized representation"
    [ "a"; "b" ]
    (Path.Rel.components (rel "a/b"));
  List.iter
    (fun component ->
      equal (result string error)
        ~msg:("component rejects " ^ String.escaped component)
        (Error (Path.Error.Malformed_component component))
        (Result.map Path.Rel.to_string
           (Path.Rel.add_component Path.Rel.root component)))
    [ ""; "."; ".."; "a/b"; "a\\b"; "a\000b"; "C:a" ];
  List.iter
    (fun (component, expected) ->
      equal bool
        ~msg:("is_component " ^ String.escaped component)
        expected
        (Path.Rel.is_component component))
    [
      ("a", true);
      ("a.ml", true);
      ("", false);
      (".", false);
      ("..", false);
      ("a/b", false);
      ("a\\b", false);
      ("a\000b", false);
      ("C:a", false);
    ];
  equal_result "add_component appends one component" (Ok "a/b")
    (Result.map Path.Rel.to_string (Path.Rel.add_component (rel "a") "b"));
  equal_result "add_component rejects separators"
    (Error (Path.Error.Malformed_component "a/b"))
    (Result.map Path.Rel.to_string (Path.Rel.add_component Path.Rel.root "a/b"))

let rel_composes_and_relativizes () =
  let src = rel "src" in
  let file = rel "src/lib/a.ml" in
  equal string ~msg:"append appends relative paths" "src/lib/a.ml"
    (Path.Rel.to_string (Path.Rel.append src (rel "lib/a.ml")));
  equal_result "resolve normalizes below root" (Ok "src/test/a.ml")
    (Result.map Path.Rel.to_string (Path.Rel.resolve src "lib/../test/a.ml"));
  equal (option string) ~msg:"relativize returns suffix" (Some "lib/a.ml")
    (Option.map Path.Rel.to_string (Path.Rel.relativize ~root:src file));
  equal (option string) ~msg:"relativize rejects sibling prefixes" None
    (Option.map Path.Rel.to_string
       (Path.Rel.relativize ~root:src (rel "src-lib/a.ml")));
  equal (option string) ~msg:"relativize rejects ancestors" None
    (Option.map Path.Rel.to_string
       (Path.Rel.relativize ~root:(rel "src/lib") src));
  is_true ~msg:"relativize recognizes descendants"
    (Option.is_some (Path.Rel.relativize ~root:src file));
  equal string ~msg:"reach descends directly" "lib/a.ml"
    (Path.Rel.reach ~from:src file);
  equal string ~msg:"reach can go through parent directories" "../../test/a.ml"
    (Path.Rel.reach ~from:(rel "src/lib") (rel "test/a.ml"))

let rel_compares_and_collects () =
  let normalized = rel "src/./a.ml" in
  let path = rel "src/a.ml" in
  is_true ~msg:"equal recognizes normalized paths"
    (Path.Rel.equal normalized path);
  equal int ~msg:"compare recognizes normalized paths" 0
    (Path.Rel.compare normalized path);
  equal int ~msg:"hash recognizes normalized paths" (Path.Rel.hash normalized)
    (Path.Rel.hash path);
  is_true ~msg:"set membership uses normalized keys"
    (Path.Rel.Set.mem normalized (Path.Rel.Set.singleton path));
  equal (option string) ~msg:"map lookup uses normalized keys" (Some "file")
    (Path.Rel.Map.find_opt normalized (Path.Rel.Map.singleton path "file"))

let abs_parses_and_normalizes () =
  List.iter
    (fun (path, expected) -> equal_result path (Ok expected) (abs_string path))
    [
      ("/", "/");
      ("/a", "/a");
      ("/a//./b/.", "/a/b");
      ("/a/../b", "/b");
      ("/../a", "/a");
    ]

let abs_rejects_invalid_input () =
  List.iter
    (fun (path, expected) ->
      equal_result path (Error expected) (abs_string path))
    [
      ("", Path.Error.Empty);
      ("a", Path.Error.Relative);
      ("\\a", Path.Error.Relative);
      ("C:a", Path.Error.Relative);
      ("/a\\b", Path.Error.Malformed_component "a\\b");
      ("/a\000b", Path.Error.Malformed_component "a\000b");
    ];
  expect_invalid_arg
    ~expected:"Spice_path.Abs.of_string_exn \"a\": path must be absolute"
    "of_string_exn rejects invalid constants" (fun () ->
      Path.Abs.of_string_exn "a" |> Path.Abs.to_string)

let abs_components_and_accessors () =
  equal string ~msg:"root formats as slash" "/"
    (Path.Abs.to_string Path.Abs.root);
  is_true ~msg:"root is recognized" (Path.Abs.is_root Path.Abs.root);
  equal (list string) ~msg:"root has no components" []
    (Path.Abs.components Path.Abs.root);
  equal (option string) ~msg:"root has no parent" None
    (Option.map Path.Abs.to_string (Path.Abs.parent Path.Abs.root));
  equal (option string) ~msg:"root has no basename" None
    (Path.Abs.basename Path.Abs.root);
  equal (list string) ~msg:"components expose normalized representation"
    [ "a"; "b" ]
    (Path.Abs.components (abs "/a/b"));
  equal_result "add_component appends one component" (Ok "/a/b")
    (Result.map Path.Abs.to_string (Path.Abs.add_component (abs "/a") "b"));
  equal_result "add_component rejects separators"
    (Error (Path.Error.Malformed_component "a/b"))
    (Result.map Path.Abs.to_string (Path.Abs.add_component Path.Abs.root "a/b"))

let abs_composes_and_relativizes () =
  let root = abs "/workspace" in
  let file = abs "/workspace/src/a.ml" in
  equal string ~msg:"append_rel appends a relative path" "/workspace/src/a.ml"
    (Path.Abs.to_string (Path.Abs.append_rel root (rel "src/a.ml")));
  equal string ~msg:"append_rel handles the absolute root" "/src/a.ml"
    (Path.Abs.to_string (Path.Abs.append_rel Path.Abs.root (rel "src/a.ml")));
  equal_result "resolve accepts relative fragments" (Ok "/test/a.ml")
    (Result.map Path.Abs.to_string (Path.Abs.resolve root "../test/a.ml"));
  equal_result "resolve rejects absolute fragments" (Error Path.Error.Absolute)
    (Result.map Path.Abs.to_string (Path.Abs.resolve root "/test/a.ml"));
  equal (option string) ~msg:"relativize returns relative suffix"
    (Some "src/a.ml")
    (Option.map Path.Rel.to_string (Path.Abs.relativize ~root file));
  equal (option string) ~msg:"relativize rejects sibling prefixes" None
    (Option.map Path.Rel.to_string
       (Path.Abs.relativize ~root (abs "/workspace2/a.ml")));
  equal (option string) ~msg:"relativize rejects ancestors" None
    (Option.map Path.Rel.to_string
       (Path.Abs.relativize ~root:(abs "/workspace/src") root));
  is_true ~msg:"relativize recognizes descendants"
    (Option.is_some (Path.Abs.relativize ~root file));
  equal string ~msg:"reach can go through parent directories" "../test/a.ml"
    (Path.Abs.reach ~from:(abs "/workspace/src") (abs "/workspace/test/a.ml"))

let abs_resolve_any_dispatches () =
  let base = abs "/workspace/project" in
  equal_result "absolute input is normalized as-is, ignoring base"
    (Ok "/etc/hosts")
    (Result.map Path.Abs.to_string (Path.Abs.resolve_any ~base "/etc/hosts"));
  equal_result "absolute input collapses . and .. components" (Ok "/etc/hosts")
    (Result.map Path.Abs.to_string
       (Path.Abs.resolve_any ~base "/etc/./sub/../hosts"));
  equal_result "relative input resolves below base"
    (Ok "/workspace/project/src/a.ml")
    (Result.map Path.Abs.to_string (Path.Abs.resolve_any ~base "src/a.ml"));
  equal_result "relative .. climbs against base" (Ok "/workspace/src/a.ml")
    (Result.map Path.Abs.to_string (Path.Abs.resolve_any ~base "../src/a.ml"));
  equal_result "empty input is rejected" (Error Path.Error.Empty)
    (Result.map Path.Abs.to_string (Path.Abs.resolve_any ~base ""));
  equal_result "malformed relative component is rejected"
    (Error (Path.Error.Malformed_component "a\000b"))
    (Result.map Path.Abs.to_string (Path.Abs.resolve_any ~base "a\000b"))

let abs_compares_and_collects () =
  let normalized = abs "/workspace/./src/a.ml" in
  let path = abs "/workspace/src/a.ml" in
  is_true ~msg:"equal recognizes normalized paths"
    (Path.Abs.equal normalized path);
  equal int ~msg:"compare recognizes normalized paths" 0
    (Path.Abs.compare normalized path);
  equal int ~msg:"hash recognizes normalized paths" (Path.Abs.hash normalized)
    (Path.Abs.hash path);
  is_true ~msg:"set membership uses normalized keys"
    (Path.Abs.Set.mem normalized (Path.Abs.Set.singleton path));
  equal (option string) ~msg:"map lookup uses normalized keys" (Some "file")
    (Path.Abs.Map.find_opt normalized (Path.Abs.Map.singleton path "file"))

let pretty_printers_match_to_string () =
  equal string ~msg:"relative pp" "src/a.ml"
    (Format.asprintf "%a" Path.Rel.pp (rel "src/a.ml"));
  equal string ~msg:"absolute pp" "/src/a.ml"
    (Format.asprintf "%a" Path.Abs.pp (abs "/src/a.ml"))

let rel_round_trips path =
  equal (result rel_path error) ~msg:"to_string parses back to same path"
    (Ok path)
    (Path.Rel.of_string (Path.Rel.to_string path));
  let text =
    match Path.Rel.components path with [] -> "." | cs -> String.concat "/" cs
  in
  equal (result rel_path error) ~msg:"components reconstruct same path"
    (Ok path) (Path.Rel.of_string text)

let rel_append_relativize (root, suffix) =
  let path = Path.Rel.append root suffix in
  equal (option rel_path) ~msg:"relativize recovers appended suffix"
    (Some suffix)
    (Path.Rel.relativize ~root path)

let rel_reach_resolves (from, target) =
  equal (result rel_path error) ~msg:"reach resolves back to target" (Ok target)
    (Path.Rel.resolve from (Path.Rel.reach ~from target))

let abs_round_trips path =
  equal (result abs_path error) ~msg:"to_string parses back to same path"
    (Ok path)
    (Path.Abs.of_string (Path.Abs.to_string path));
  equal (result abs_path error) ~msg:"components reconstruct same path"
    (Ok path)
    (Path.Abs.of_string ("/" ^ String.concat "/" (Path.Abs.components path)))

let abs_append_relativize (root, suffix) =
  let path = Path.Abs.append_rel root suffix in
  equal (option rel_path) ~msg:"relativize recovers appended suffix"
    (Some suffix)
    (Path.Abs.relativize ~root path)

let abs_reach_resolves (from, target) =
  equal (result abs_path error) ~msg:"reach resolves back to target" (Ok target)
    (Path.Abs.resolve from (Path.Abs.reach ~from target))

let abs_resolve_any_normalizes_absolute (base, path) =
  equal (result abs_path error)
    ~msg:"resolve_any on an absolute string ignores base and yields it back"
    (Ok path)
    (Path.Abs.resolve_any ~base (Path.Abs.to_string path))

let abs_resolve_any_agrees_with_resolve (base, suffix) =
  let text = Path.Rel.to_string suffix in
  equal (result abs_path error)
    ~msg:"resolve_any on relative input agrees with resolve"
    (Path.Abs.resolve base text)
    (Path.Abs.resolve_any ~base text)

let error_message_names_malformed_component () =
  let message =
    match Path.Rel.add_component (rel "dir") "C:temp" with
    | Ok path ->
        failf "expected malformed component, got %s" (Path.Rel.to_string path)
    | Error error -> Path.Error.message error
  in
  is_true ~msg:"message names the rejected component"
    (Option.is_some (String.find_first ~sub:"C:temp" message))

let raw_relative_resolve_preserves_invariants (start, input) =
  match Path.Rel.resolve start input with
  | Error _ -> ()
  | Ok path ->
      equal (result rel_path error)
        ~msg:("resolved relative path re-parses: " ^ String.escaped input)
        (Ok path)
        (Path.Rel.of_string (Path.Rel.to_string path));
      List.iter
        (fun component ->
          is_true
            ~msg:("resolved component is valid: " ^ String.escaped component)
            (Path.Rel.is_component component))
        (Path.Rel.components path)

let raw_absolute_parse_preserves_invariants input =
  match Path.Abs.of_string input with
  | Error _ -> ()
  | Ok path ->
      equal (result abs_path error)
        ~msg:("parsed absolute path re-parses: " ^ String.escaped input)
        (Ok path)
        (Path.Abs.of_string (Path.Abs.to_string path));
      List.iter
        (fun component ->
          is_true
            ~msg:("parsed component is valid: " ^ String.escaped component)
            (Path.Rel.is_component component))
        (Path.Abs.components path)

let () =
  run "spice.path"
    [
      group "relative"
        [
          test "parses and normalizes" rel_parses_and_normalizes;
          test "rejects invalid input" rel_rejects_invalid_input;
          test "components and accessors" rel_components_and_accessors;
          test "composes and relativizes" rel_composes_and_relativizes;
          test "compares and collects" rel_compares_and_collects;
          prop' "round-trips generated paths" rel_path rel_round_trips;
          prop' "relativizes appended suffixes" (pair rel_path rel_path)
            rel_append_relativize;
          prop' "resolves reach output" (pair rel_path rel_path)
            rel_reach_resolves;
          prop' "raw resolve inputs preserve invariants"
            (pair rel_path raw_path_input)
            raw_relative_resolve_preserves_invariants;
        ];
      group "absolute"
        [
          test "parses and normalizes" abs_parses_and_normalizes;
          test "rejects invalid input" abs_rejects_invalid_input;
          test "components and accessors" abs_components_and_accessors;
          test "composes and relativizes" abs_composes_and_relativizes;
          test "resolve_any dispatches on absolute versus relative input"
            abs_resolve_any_dispatches;
          test "compares and collects" abs_compares_and_collects;
          prop' "round-trips generated paths" abs_path abs_round_trips;
          prop' "relativizes appended suffixes" (pair abs_path rel_path)
            abs_append_relativize;
          prop' "resolves reach output" (pair abs_path abs_path)
            abs_reach_resolves;
          prop' "resolve_any normalizes absolute strings"
            (pair abs_path abs_path) abs_resolve_any_normalizes_absolute;
          prop' "resolve_any agrees with resolve on relative input"
            (pair abs_path rel_path) abs_resolve_any_agrees_with_resolve;
          prop' "raw parser inputs preserve invariants" raw_path_input
            raw_absolute_parse_preserves_invariants;
        ];
      test "error message names the malformed component"
        error_message_names_malformed_component;
      test "pretty printers match to_string" pretty_printers_match_to_string;
    ]
