(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Dune = Spice_ocaml_dune
module Editor = Spice_tools.Editor
module Shell = Spice_tools.Shell
module Tool = Spice_tool
module Workspace = Spice_workspace

let sandbox = Spice_sandbox.seal Spice_sandbox.Policy.direct

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid absolute test path %S: %s" path
        (Spice_path.Error.message error)

let with_workspace f =
  let dir = Filename.temp_file "spice-catalog-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let root = Unix.realpath dir in
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir root with _ -> ())
    (fun () ->
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env ->
      let fs = Eio.Stdenv.fs env in
      f ~fs
        ~process_mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env) ~cwd:(Eio.Path.( / ) fs root)
        ~net:(Eio.Stdenv.net env) ~workspace)

let print_catalog label tools =
  Printf.printf "-- %s --\n" label;
  List.iter (fun tool -> Printf.printf "%s\n" (Tool.name tool)) tools

let catalog ~editor ~fs ~process_mgr ~clock ~cwd ~dune ~workspace ~shell =
  List.concat
    [
      Spice_tools.files ~fs ~workspace ();
      Spice_tools.search ~sandbox ~fs ~workspace ();
      Spice_tools.edits ~editor ~fs ~workspace ();
      Spice_tools.ocaml ~sandbox ~fs ~process_mgr ~clock ~cwd ~dune ~workspace
        ();
      Spice_tools.shell ~fs ~workspace ~config:shell ();
    ]

let%expect_test "default catalog selects editor tools by family" =
  with_workspace @@ fun ~fs ~process_mgr ~clock ~cwd ~net ~workspace ->
  let dune = Dune.Rpc.Instance.create ~fs ~net ~workspace () in
  let shell = Shell.Config.make () in
  let default ~editor () =
    catalog ~editor ~fs ~process_mgr ~clock ~cwd ~dune ~workspace ~shell
  in
  (* The editor family owns the whole general mutation surface: exactly one
     family ships, and write_file rides with edit_file. *)
  print_catalog "editor apply-patch" (default ~editor:Editor.Apply_patch ());
  print_catalog "editor string-replace"
    (default ~editor:Editor.String_replace ());
  [%expect
    {|
    -- editor apply-patch --
    read_file
    search_text
    glob
    apply_patch
    ocaml_ast_edit
    ocaml_eval
    ocaml_rename
    ocaml_replace_expressions
    ocaml_dune_describe
    ocaml_dune_diagnostics
    ocaml_docs
    ocaml_find_definitions
    ocaml_find_references
    ocaml_search_expressions
    ocaml_type_at
    shell
    -- editor string-replace --
    read_file
    search_text
    glob
    write_file
    edit_file
    ocaml_ast_edit
    ocaml_eval
    ocaml_rename
    ocaml_replace_expressions
    ocaml_dune_describe
    ocaml_dune_diagnostics
    ocaml_docs
    ocaml_find_definitions
    ocaml_find_references
    ocaml_search_expressions
    ocaml_type_at
    shell |}]

(* Gemini restricts function names to 64 bytes of [A-Za-z0-9_.-] starting
   with a letter or underscore; the registry must never ship a name the
   strictest provider dialect rejects. *)
let%expect_test "tool names satisfy the strictest provider name dialect" =
  with_workspace @@ fun ~fs ~process_mgr ~clock ~cwd ~net ~workspace ->
  let dune = Dune.Rpc.Instance.create ~fs ~net ~workspace () in
  let shell = Shell.Config.make () in
  let tools =
    catalog ~editor:Editor.String_replace ~fs ~process_mgr ~clock ~cwd ~dune
      ~workspace ~shell
  in
  let valid_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '-' -> true
    | _ -> false
  in
  let valid name =
    String.length name >= 1
    && String.length name <= 64
    && (match name.[0] with
      | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
      | _ -> false)
    && String.for_all valid_char name
  in
  List.iter
    (fun tool ->
      let name = Tool.name tool in
      if not (valid name) then
        Printf.printf "INVALID: %s (%d bytes)\n" name (String.length name))
    tools;
  Printf.printf "checked %d tool names\n" (List.length tools);
  [%expect {| checked 17 tool names |}]

[%%run_tests "spice.tools.catalog.expect"]
