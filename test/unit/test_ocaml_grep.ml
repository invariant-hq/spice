(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Grep = Spice_ocaml_grep
module Ocaml = Spice_ocaml

let workspace_path =
  let root =
    Spice_workspace.Root.make (Spice_path.Abs.of_string_exn "/workspace")
  in
  Spice_workspace.Path.make ~root (Spice_path.Rel.of_string_exn "test.ml")

let line_starts source =
  let starts = ref [ 0 ] in
  String.iteri (fun i c -> if c = '\n' then starts := (i + 1) :: !starts) source;
  Array.of_list (List.rev !starts)

let slice source location =
  let starts = line_starts source in
  let offset position =
    starts.(Ocaml.Position.line position - 1) + Ocaml.Position.column position
  in
  let range = Ocaml.Location.range location in
  let start_offset = offset (Ocaml.Range.start range) in
  let end_offset = offset (Ocaml.Range.end_ range) in
  String.sub source start_offset (end_offset - start_offset)

let slice_range source range =
  let starts = line_starts source in
  let offset position =
    starts.(Ocaml.Position.line position - 1) + Ocaml.Position.column position
  in
  let start_offset = offset (Ocaml.Range.start range) in
  let end_offset = offset (Ocaml.Range.end_ range) in
  String.sub source start_offset (end_offset - start_offset)

let binding_text source binding =
  let rendered =
    match Grep.Binding.captured binding with
    | Grep.Binding.Source range -> "Source(" ^ slice_range source range ^ ")"
    | Grep.Binding.Ident ident -> "Ident(" ^ ident ^ ")"
  in
  Grep.Binding.name binding ^ "=" ^ rendered

let bindings pattern source =
  match Grep.Pattern.parse pattern with
  | Error error ->
      failf "pattern %S: %s" pattern (Grep.Pattern.error_message error)
  | Ok parsed -> (
      match Grep.parse_implementation ~filename:"test.ml" source with
      | Error error ->
          failf "source did not parse: %s" (Grep.Parse_error.to_string error)
      | Ok structure ->
          Grep.search_with_bindings parsed ~path:workspace_path structure
          |> List.map (fun (location, bs) ->
              slice source location ^ " => "
              ^ String.concat ", " (List.map (binding_text source) bs)))

let check_bindings pattern source expected =
  equal (list string) ~msg:pattern expected (bindings pattern source)

let find pattern source =
  match Grep.Pattern.parse pattern with
  | Error error ->
      failf "pattern %S: %s" pattern (Grep.Pattern.error_message error)
  | Ok parsed -> (
      match Grep.parse_implementation ~filename:"test.ml" source with
      | Error error ->
          failf "source did not parse: %s" (Grep.Parse_error.to_string error)
      | Ok structure ->
          Grep.search parsed ~path:workspace_path structure
          |> List.map (slice source))

let check pattern source expected =
  equal (list string) ~msg:pattern expected (find pattern source)

let parse_expr source =
  match Parse.expression (Lexing.from_string source) with
  | expr -> expr
  | exception exn ->
      failf "expression %S did not parse: %s" source (Printexc.to_string exn)

let pattern_api () =
  List.iter
    (fun (name, expected) ->
      equal bool ~msg:name expected (Grep.Pattern.is_metavariable_name name))
    [
      ("__", false);
      ("__1", true);
      ("__23", true);
      ("__a", false);
      ("__1a", false);
    ];
  let pattern =
    match
      Grep.Pattern.parse "match __1 with Some __2 -> __2 | None -> __.field"
    with
    | Ok pattern -> pattern
    | Error error ->
        failf "pattern parse failed: %s" (Grep.Pattern.error_message error)
  in
  equal (list string) ~msg:"metavariables" [ "__1"; "__2" ]
    (Grep.Pattern.metavariables pattern);
  is_true ~msg:"structural expression equality ignores locations"
    (Grep.structurally_equal_expr (parse_expr "f  x") (parse_expr "f x"))

let identifier_suffix () =
  let source = "let ys = List.filter pred xs\nlet n = String.length s\n" in
  check "List.filter" source [ "List.filter" ];
  check "filter" source [ "List.filter" ];
  check "Stdlib.List.filter" source [ "List.filter" ];
  check "String.filter" source [];
  check "length" source [ "String.length" ]

let application_and_omission () =
  let source = "let r = List.fold_left combine init (List.map f xs)\n" in
  check "List.fold_left __ __ (List.map __ __)" source
    [ "List.fold_left combine init (List.map f xs)" ];
  check "List.fold_left" source [ "List.fold_left" ];
  check "List.fold_left combine" source
    [ "List.fold_left combine init (List.map f xs)" ];
  check "List.rev __ @ __" source [];
  let rev_source = "let joined = List.rev acc @ rest\n" in
  check "List.rev __ @ __" rev_source [ "List.rev acc @ rest" ]

let optional_arguments () =
  let with_arg = "let v = create ?capacity:(Some n) ()\n" in
  let without_arg = "let v = create ()\n" in
  check "create ?capacity:PRESENT" with_arg [ "create ?capacity:(Some n) ()" ];
  check "create ?capacity:MISSING" with_arg [];
  check "create ?capacity:PRESENT" without_arg [];
  check "create ?capacity:MISSING" without_arg [ "create ()" ]

let metavariables () =
  let source = "let a = x :: x\nlet b = x :: y\n" in
  check "__1 :: __1" source [ "x :: x" ];
  check "__1 :: __2" source [ "x :: x"; "x :: y" ]

let clause_sets () =
  let source =
    "let f o = match o with Some v -> Some v | None -> None\n\
     let g o = match o with None -> None | Some v -> Some v\n"
  in
  check "match __ with None -> __ | Some __1 -> Some __1" source
    [
      "match o with Some v -> Some v | None -> None";
      "match o with None -> None | Some v -> Some v";
    ]

let formatting_invariance () =
  let source = "let result =\n  List.map\n    transform\n    (load input)\n" in
  check "List.map __ (load __)" source
    [ "List.map\n    transform\n    (load input)" ]

let record_fields () =
  let source = "let p = { x = 1; y = 2 }\nlet q = { x = 1 }\n" in
  check "{ x = __; y = __ }" source [ "{ x = 1; y = 2 }" ];
  check "{ y = 2; x = 1 }" source [ "{ x = 1; y = 2 }" ];
  check "{ x = __ }" source [ "{ x = 1 }" ];
  check "{ __ = __ }" source [ "{ x = 1; y = 2 }"; "{ x = 1 }" ]

let mixed_set_patterns_backtrack () =
  check "{ __1 = __2; x = __2 }" "let r = { x = 1; y = 1 }\n"
    [ "{ x = 1; y = 1 }" ];
  check "{ __1 = __2; x = __2 }" "let r = { y = 1; x = 1 }\n"
    [ "{ y = 1; x = 1 }" ];
  let clauses =
    "let f = function\n\
    \  | Some 1 -> true\n\
    \  | None -> false\n\
    \  | Some n -> n > 0\n"
  in
  check "function __ -> __ | None -> false" clauses
    [ "function\n  | Some 1 -> true\n  | None -> false\n  | Some n -> n > 0" ]

let field_access_and_patterns () =
  let source =
    "let read r = r.name\n\
     let write r = r.name <- \"x\"\n\
     let destructure { name; _ } = name\n"
  in
  check "__.name" source [ "r.name"; "r.name <- \"x\""; "{ name; _ }" ]

let annotation_transparency () =
  let source =
    "let y = (x : int) + 1\nlet f = fun (a : string) -> ignore a\n"
  in
  check "x + 1" source [ "(x : int) + 1" ];
  check "fun a -> ignore a" source [ "fun (a : string) -> ignore a" ]

let binding_sets () =
  let source = "let v = let b = 2 and a = 1 in a + b\n" in
  check "let a = 1 and b = 2 in __" source [ "let b = 2 and a = 1 in a + b" ]

let unsupported_patterns () =
  let expect_unsupported pattern =
    match Grep.Pattern.parse pattern with
    | Error (Grep.Pattern.Unsupported _) -> ()
    | Error (Grep.Pattern.Syntax error) ->
        failf "%s: expected Unsupported, got Syntax %s" pattern
          error.Grep.Pattern.message
    | Ok _ -> failf "%s: expected Unsupported, got Ok" pattern
  in
  expect_unsupported "(__ : int list)";
  expect_unsupported "(__ :> t)";
  expect_unsupported "let x : int = 1 in x";
  expect_unsupported "fun (x : int) -> x";
  match Grep.Pattern.parse "let x =" with
  | Error (Grep.Pattern.Syntax _) -> ()
  | Error (Grep.Pattern.Unsupported message) ->
      failf "expected Syntax, got Unsupported %s" message
  | Ok _ -> failf "expected Syntax error, got Ok"

let pattern_syntax_errors () =
  match Grep.Pattern.parse "match __ with __" with
  | Error (Grep.Pattern.Syntax error) ->
      equal string ~msg:"compiler message" "Syntax error"
        error.Grep.Pattern.message;
      begin match error.Grep.Pattern.position with
      | Some position ->
          equal int ~msg:"line" 1 (Ocaml.Position.line position);
          equal int ~msg:"column" 16 (Ocaml.Position.column position)
      | None -> failf "expected parser error position"
      end;
      equal string ~msg:"diagnostic formatter"
        "Syntax error at line 1, column 16"
        (Format.asprintf "%a" Grep.Pattern.pp_error (Grep.Pattern.Syntax error))
  | Error (Grep.Pattern.Unsupported message) ->
      failf "expected Syntax, got Unsupported %s" message
  | Ok _ -> failf "expected Syntax error, got Ok"

let source_parse_errors () =
  match Grep.parse_implementation ~filename:"broken.ml" "let x =\n" with
  | Error error ->
      equal string ~msg:"filename" "broken.ml" (Grep.Parse_error.filename error);
      equal string ~msg:"message" "syntax error"
        (Grep.Parse_error.message error);
      is_true ~msg:"diagnostic mentions a syntax error"
        (String.length (Grep.Parse_error.to_string error) > 0);
      begin match Grep.Parse_error.position error with
      | Some position ->
          equal int ~msg:"line" 2 (Ocaml.Position.line position);
          equal int ~msg:"column" 0 (Ocaml.Position.column position)
      | None -> failf "expected parser error position"
      end
  | Ok _ -> failf "expected a syntax error for broken source"

let binding_flagship_upgrade () =
  (* The Option.value flagship: __1 and __2 are expression captures; __3 is
     first bound as an identifier in [Some v] and upgraded to the real source
     of the right-hand [v] occurrence. Either way it renders "v". *)
  let source = "let f o = match o with None -> fallback () | Some v -> v\n" in
  check_bindings "match __1 with None -> __2 | Some __3 -> __3" source
    [
      "match o with None -> fallback () | Some v -> v => __1=Source(o), \
       __2=Source(fallback ()), __3=Source(v)";
    ]

let binding_ident_capture () =
  (* A metavariable that only ever occupies a field-component position binds a
     bare identifier and renders as [Ident]; there is no source range. *)
  let source = "let read r = r.name\n" in
  check_bindings "__.__1" source [ "r.name => __1=Ident(name)" ]

let binding_first_occurrence_text () =
  (* Repeated expression metavariable: the captured text is the first
     occurrence's source bytes, spacing and all, even though the two stripped
     fragments unify. *)
  let source = "let a = f  x :: f x\n" in
  check_bindings "__1 :: __1" source [ "f  x :: f x => __1=Source(f  x)" ]

let binding_multiline_fragment () =
  let source = "let r =\n  g\n    (a\n     + b)\n" in
  check_bindings "g __1" source
    [ "g\n    (a\n     + b) => __1=Source((a\n     + b))" ]

let binding_excludes_pattern_matches () =
  (* [__.id] pattern-position matches carry no metavariables and are not rewrite
     targets, so [search_with_bindings] omits them; only the expression reads
     remain, each with an empty binding list. *)
  let source =
    "let read r = r.name\n\
     let write r = r.name <- \"x\"\n\
     let destructure { name; _ } = name\n"
  in
  check_bindings "__.name" source [ "r.name => "; "r.name <- \"x\" => " ]

let binding_disjoint_ranges () =
  (* Matched ranges within a file are pairwise disjoint: an outer match is not
     descended into, so a nested occurrence is not reported. *)
  let source = "let a = f (f x) y\n" in
  check_bindings "f __1" source [ "f (f x) y => __1=Source((f x))" ]

let () =
  run "spice.ocaml.grep"
    [
      test "pattern API" pattern_api;
      test "binding capture: flagship ghost-to-real upgrade"
        binding_flagship_upgrade;
      test "binding capture: identifier-only metavariable" binding_ident_capture;
      test "binding capture: first-occurrence source text"
        binding_first_occurrence_text;
      test "binding capture: multi-line fragment range"
        binding_multiline_fragment;
      test "binding capture: pattern matches excluded"
        binding_excludes_pattern_matches;
      test "binding capture: disjoint match ranges" binding_disjoint_ranges;
      test "identifier suffix matching" identifier_suffix;
      test "application and argument omission" application_and_omission;
      test "optional argument PRESENT/MISSING" optional_arguments;
      test "metavariable unification" metavariables;
      test "clause set order independence" clause_sets;
      test "formatting invariance" formatting_invariance;
      test "record field sets" record_fields;
      test "mixed unordered set patterns backtrack" mixed_set_patterns_backtrack;
      test "field access, assignment, and patterns" field_access_and_patterns;
      test "type annotation transparency" annotation_transparency;
      test "value binding sets" binding_sets;
      test "unsupported patterns are rejected" unsupported_patterns;
      test "pattern syntax errors preserve compiler diagnostics"
        pattern_syntax_errors;
      test "source parse errors are reported" source_parse_errors;
    ]
