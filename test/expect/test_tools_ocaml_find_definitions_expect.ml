(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Find = Spice_tools.Ocaml_find_definitions
module Json = Jsont.Json
module Tool = Spice_tool
module Workspace = Spice_workspace

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
  let dir = Filename.temp_file "spice-ocaml-find-def-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f (Unix.realpath dir))

let write_project root =
  write_disk (path root "dune-project") "(lang dune 3.0)\n(name fixture)\n";
  write_disk (path root "lib/dune") "(library (name fixture_lib))\n";
  write_disk (path root "lib/main.ml") "let answer = 42\nlet use = answer\n"

let write_fake_merlin root =
  let script = path root "fake-ocamlmerlin" in
  write_disk script
    {|#!/bin/sh
if [ "$1" != "single" ]; then
  printf 'fake-ocamlmerlin: missing single selector in: %s\n' "$*" >&2
  exit 3
fi
cat >/dev/null
case " $* " in
  *" locate-type "*)
    printf '{"class":"return","value":{"file":"/external/pkg/type.ml","pos":{"line":7,"col":2}}}\n'
    ;;
  *" -prefix answer "*)
    printf '{"class":"return","value":{"pos":{"line":1,"col":4}}}\n'
    ;;
  *" -position 1:4 "*)
    printf '{"class":"return","value":"Already at definition point"}\n'
    ;;
  *)
    printf '{"class":"return","value":"didn'\''t manage to find missing"}\n'
    ;;
esac
|};
  Unix.chmod script 0o755;
  script

let with_project f =
  with_temp_dir @@ fun root ->
  write_project root;
  let merlin = write_fake_merlin root in
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env ->
  f ~root ~merlin ~fs:(Eio.Stdenv.fs env)
    ~cwd:(Eio.Path.( / ) (Eio.Stdenv.fs env) root)
    ~workspace

let print_decode label json =
  match Find.Input.decode json with
  | Ok input ->
      Printf.printf "%s: ok %s %d:%d %s\n" label (Find.Input.path input)
        (Find.Input.line input) (Find.Input.column input)
        (Find.Input.Kind.to_string (Find.Input.kind input))
  | Error message -> Printf.printf "%s: error %s\n" label message

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

let print_output result =
  print_status result;
  match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Find.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some evidence ->
          Printf.printf "definitions: %d\n"
            (Find.Output.definition_count evidence);
          print_endline (Tool.Output.text output))

let decode_call tool input =
  match Tool.Call.decode [ tool ] ~name:Find.name ~input () with
  | Ok call -> call
  | Error error -> failf "decode failed: %a" Tool.Error.pp error

let%expect_test "input contract validates source coordinates and lookup kind" =
  print_decode "minimal"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 2);
         ("column", Json.int 10);
       ]);
  print_decode "explicit declaration"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 2);
         ("column", Json.int 10);
         ("identifier", Json.string "answer");
         ("kind", Json.string "declaration");
       ]);
  print_decode "bad line"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 0);
         ("column", Json.int 10);
       ]);
  print_decode "bad kind"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int 0);
         ("kind", Json.string "implementation");
       ]);
  print_decode "type with identifier"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 2);
         ("column", Json.int 10);
         ("identifier", Json.string "answer");
         ("kind", Json.string "type-definition");
       ]);
  [%expect
    {|
    minimal: ok lib/main.ml 2:10 definition
    explicit declaration: ok lib/main.ml 2:10 declaration
    bad line: error line must be at least 1
    bad kind: error unknown kind: implementation
    type with identifier: error identifier cannot be used with type-definition lookups |}]

let%expect_test "tool locates a workspace definition through Merlin output" =
  with_project @@ fun ~root:_ ~merlin ~fs ~cwd:_ ~workspace ->
  let tool = Find.tool ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/main.ml");
        ("line", Json.int 2);
        ("column", Json.int 10);
        ("identifier", Json.string "answer");
      ]
  in
  let call = decode_call tool input in
  Printf.printf "tool: %s\n" (Tool.Call.tool call);
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  Tool.Call.run call () |> print_output;
  [%expect
    {|
    tool: ocaml_find_definitions
    permissions: 1
    status: completed
    definitions: 1
    OCaml definitions: 1
    - lib/main.ml:1:4-1:4
    index_status: unknown |}]

let%expect_test "tool preserves external definition targets" =
  with_project @@ fun ~root:_ ~merlin ~fs ~cwd:_ ~workspace ->
  let tool = Find.tool ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/main.ml");
        ("line", Json.int 2);
        ("column", Json.int 10);
        ("kind", Json.string "type-definition");
      ]
  in
  let call = decode_call tool input in
  Tool.Call.run call () |> print_output;
  [%expect
    {|
    status: completed
    definitions: 1
    OCaml definitions: 1
    - /external/pkg/type.ml:7:2
    index_status: unknown |}]

let%expect_test "tool reports Merlin not-found as a typed tool failure" =
  with_project @@ fun ~root:_ ~merlin ~fs ~cwd:_ ~workspace ->
  let tool = Find.tool ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/main.ml");
        ("line", Json.int 2);
        ("column", Json.int 10);
      ]
  in
  let call = decode_call tool input in
  Tool.Call.run call () |> print_output;
  [%expect
    {|
    status: failed not_found: didn't manage to find missing
    output: none |}]

let%expect_test "already at definition point returns the cursor location" =
  with_project @@ fun ~root:_ ~merlin ~fs ~cwd:_ ~workspace ->
  let tool = Find.tool ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/main.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
      ]
  in
  let call = decode_call tool input in
  Tool.Call.run call () |> print_output;
  [%expect
    {|
    status: completed
    definitions: 1
    OCaml definitions: 1
    - lib/main.ml:1:4-1:4
    index_status: not_applicable |}]

[%%run_tests "spice.tools.ocaml_find_definitions.expect"]
