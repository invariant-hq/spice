(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Ast_edit = Spice_tools.Ocaml_ast_edit
module Tool = Spice_tool
module Workspace = Spice_workspace

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid absolute test path %S: %s" path
        (Spice_path.Error.message error)

let test_path =
  let root = Workspace.Root.make (abs "/workspace") in
  Workspace.Path.make ~root (Spice_path.Rel.of_string_exn "lib/example.ml")

let source =
  String.concat "\n"
    [
      "module M = struct";
      "  type t = int";
      "  let add x = x + 1";
      "end";
      "";
      "let outside = M.add 2";
      "";
    ]

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

let read_disk file =
  let ic = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let with_temp_dir f =
  let dir = Filename.temp_file "spice-ocaml-ast-edit-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  write_disk (path root "lib/example.ml") source;
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env -> f ~root ~fs:(Eio.Stdenv.fs env) ~workspace

let position line column = Spice_ocaml.Position.make ~line ~column

let range start_line start_column end_line end_column =
  Spice_ocaml.Range.make
    ~start:(position start_line start_column)
    ~end_:(position end_line end_column)

let print_plan result =
  match result with
  | Error error -> Printf.printf "error: %s\n" (Ast_edit.Error.message error)
  | Ok plan ->
      Printf.printf "after:\n%s" (Ast_edit.Plan.after_contents plan);
      List.iter
        (fun resolved ->
          Printf.printf "selected %s: %S\n"
            (Format.asprintf "%a" Spice_ocaml.Range.pp
               (Ast_edit.Resolved.range resolved))
            (Ast_edit.Resolved.selected_text resolved))
        (Ast_edit.Plan.resolved plan);
      Printf.printf "empty: %b\n"
        (Spice_edit.is_empty (Ast_edit.Plan.edit plan))

let print_run_result result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | None -> print_endline "completed without output"
      | Some output ->
          Printf.printf "path: %s\n"
            (Workspace.Path.display (Ast_edit.Output.path output));
          Printf.printf "resolved: %d edit=%b\n"
            (List.length (Ast_edit.Output.resolved output))
            (not
               (Spice_tools.Receipt.is_empty (Ast_edit.Output.receipt output)));
          Printf.printf "after:\n%s" (Ast_edit.Output.after_contents output))
  | Tool.Result.Failed { kind; message; metadata = _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason

let edit op selector text = Ast_edit.Edit.make ~op ~selector ~text ()
let delete selector = Ast_edit.Edit.make ~op:Ast_edit.Edit.Delete ~selector ()

let%expect_test "plans nested item insert and replacement edits" =
  let edits =
    [
      edit Ast_edit.Edit.Insert_after
        (Ast_edit.Selector.item ~kind:Ast_edit.Item_kind.Type [ "M"; "t" ])
        "\n  let zero = 0";
      edit Ast_edit.Edit.Replace
        (Ast_edit.Selector.item ~kind:Ast_edit.Item_kind.Value [ "M"; "add" ])
        "let add x = x + 2";
    ]
  in
  Ast_edit.plan ~path:test_path ~file_kind:Ast_edit.Implementation
    ~contents:source edits
  |> print_plan;
  [%expect
    {|
    after:
    module M = struct
      type t = int
      let zero = 0
      let add x = x + 2
    end

    let outside = M.add 2
    selected 2:2-2:14: "type t = int"
    selected 3:2-3:19: "let add x = x + 1"
    empty: false |}]

let%expect_test "plans exact expression and type replacement edits" =
  let edits =
    [
      edit Ast_edit.Edit.Replace
        (Ast_edit.Selector.exact ~kind:Ast_edit.Node_kind.Type
           ~range:(range 2 11 2 14))
        "string";
      edit Ast_edit.Edit.Replace
        (Ast_edit.Selector.exact ~kind:Ast_edit.Node_kind.Expression
           ~range:(range 6 14 6 21))
        "(M.add 2) + 1";
    ]
  in
  Ast_edit.plan ~path:test_path ~file_kind:Ast_edit.Implementation
    ~contents:source edits
  |> print_plan;
  [%expect
    {|
    after:
    module M = struct
      type t = string
      let add x = x + 1
    end

    let outside = (M.add 2) + 1
    selected 2:11-2:14: "int"
    selected 6:14-6:21: "M.add 2"
    empty: false |}]

let%expect_test "reports invalid replacement, missing selection, and overlaps" =
  Ast_edit.plan ~path:test_path ~file_kind:Ast_edit.Implementation
    ~contents:source
    [
      edit Ast_edit.Edit.Replace
        (Ast_edit.Selector.item ~kind:Ast_edit.Item_kind.Value [ "M"; "add" ])
        "let =";
    ]
  |> print_plan;
  Ast_edit.plan ~path:test_path ~file_kind:Ast_edit.Implementation
    ~contents:source
    [
      delete
        (Ast_edit.Selector.item ~kind:Ast_edit.Item_kind.Value
           [ "M"; "missing" ]);
    ]
  |> print_plan;
  Ast_edit.plan ~path:test_path ~file_kind:Ast_edit.Implementation
    ~contents:source
    [
      edit Ast_edit.Edit.Replace
        (Ast_edit.Selector.item ~kind:Ast_edit.Item_kind.Type [ "M"; "t" ])
        "  type t = string";
      edit Ast_edit.Edit.Replace
        (Ast_edit.Selector.exact ~kind:Ast_edit.Node_kind.Type
           ~range:(range 2 11 2 14))
        "float";
    ]
  |> print_plan;
  [%expect
    {|
    error: replacement item parse error at 1:4-1:5: Syntax error
    error: AST selection not found: value M.missing occurrence 1
    error: AST edits overlap: 2:2-2:14 and 2:11-2:14 |}]

let%expect_test "runs as a model-facing mutating tool" =
  with_fixture @@ fun ~root ~fs ~workspace ->
  let input =
    Ast_edit.Input.make ~path:"lib/example.ml"
      ~edits:
        [
          edit Ast_edit.Edit.Replace
            (Ast_edit.Selector.item ~kind:Ast_edit.Item_kind.Value
               [ "M"; "add" ])
            "let add x = x + 42";
        ]
      ()
  in
  Ast_edit.run ~fs ~workspace input |> print_run_result;
  Printf.printf "disk:\n%s" (read_disk (path root "lib/example.ml"));
  [%expect
    {|
    path: lib/example.ml
    resolved: 1 edit=true
    after:
    module M = struct
      type t = int
      let add x = x + 42
    end

    let outside = M.add 2
    disk:
    module M = struct
      type t = int
      let add x = x + 42
    end

    let outside = M.add 2 |}]

[%%run_tests "spice.tools.ocaml_ast_edit.expect"]
