(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Find = Spice_tools.Ocaml_find_references
module Json = Jsont.Json
module Tool = Spice_tool
module Workspace = Spice_workspace

let sandbox = Spice_sandbox.seal Spice_sandbox.Spec.Unconfined

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

let read_disk file =
  let ic = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let with_temp_dir f =
  let dir = Filename.temp_file "spice-ocaml-refs-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f (Unix.realpath dir))

let with_project f =
  with_temp_dir @@ fun root ->
  write_disk (path root "lib/a.ml") "let target = 1\nlet use = target + 1\n";
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env -> f ~root ~fs:(Eio.Stdenv.fs env) ~workspace

let write_fake_merlin root =
  let script = path root "fake-ocamlmerlin" in
  let log = path root "fake-ocamlmerlin.argv" in
  write_disk script
    (Printf.sprintf
       {|#!/bin/sh
printf '%%s\n' "$@" > %S
if [ "$1" != "single" ]; then
  printf 'fake-ocamlmerlin: missing single selector in: %%s\n' "$*" >&2
  exit 3
fi
file=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-filename" ]; then
    shift
    file=$1
  fi
  shift
done
cat >/dev/null
printf '{"class":"return","value":[{"file":"%%s","start":{"line":1,"col":4},"end":{"line":1,"col":10},"stale":false},{"file":"%%s","start":{"line":2,"col":10},"end":{"line":2,"col":16},"stale":true}],"notifications":[]}\n' "$file" "$file"
|}
       log);
  Unix.chmod script 0o755;
  (script, log)

(* A fake ocamlmerlin that returns a single occurrence whose [start] position is
   supplied verbatim, so a test can drive a malformed [{line, col}] object
   through [Ocaml_position.of_json] and observe how the tool surfaces the decode
   error. [file] is empty so the reference resolves to the queried path. *)
let write_fake_merlin_start root ~start =
  let script = path root "fake-ocamlmerlin" in
  write_disk script
    (Printf.sprintf
       {|#!/bin/sh
cat >/dev/null
printf '%%s\n' '{"class":"return","value":[{"file":"","start":%s,"end":{"line":1,"col":10},"stale":false}],"notifications":[]}'
|}
       start);
  Unix.chmod script 0o755;
  script

let print_decode label json =
  match Find.Input.decode json with
  | Ok input ->
      let position = Find.Input.position input in
      Printf.printf "%s: ok %s %d:%d %s stale=%b limit=%d\n" label
        (Find.Input.path input)
        (Spice_ocaml.Position.line position)
        (Spice_ocaml.Position.column position)
        (Find.Scope.to_string (Find.Input.scope input))
        (Find.Input.include_stale input)
        (Find.Input.limit input)
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

let decode_call tool input =
  match Tool.Call.decode [ tool ] ~name:Find.name ~input () with
  | Ok call -> call
  | Error error -> failf "decode failed: %a" Tool.Error.pp error

let index_status_text = function
  | Find.Output.Not_applicable -> "not_applicable"
  | Find.Output.Unknown -> "unknown"

let status_text = function
  | Find.Output.Complete -> "complete"
  | Find.Output.Partial -> "partial"

let%expect_test "input contract is position based and bounded" =
  print_decode "minimal"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
       ]);
  print_decode "full"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 2);
         ("column", Json.int 10);
         ("scope", Json.string "buffer");
         ("include_stale", Json.bool true);
         ("limit", Json.int 7);
       ]);
  print_decode "name only" (json_obj [ ("name", Json.string "target") ]);
  print_decode "bad scope"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("scope", Json.string "grep");
       ]);
  [%expect
    {|
    minimal: ok lib/a.ml 1:4 project stale=false limit=200
    full: ok lib/a.ml 2:10 buffer stale=true limit=7
    name only: error Unexpected member name for ocaml_find_references input object
    bad scope: error scope must be one of buffer, project, or renaming |}]

let%expect_test "tool adapter invokes backend and filters stale references" =
  with_project @@ fun ~root ~fs ~workspace ->
  let merlin, log = write_fake_merlin root in
  let tool = Find.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
      ]
  in
  let call = decode_call tool input in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  print_status result;
  let argv = read_disk log |> String.split_on_char '\n' in
  Printf.printf "argv_program: %s\n" (Filename.basename merlin);
  Printf.printf "argv_selector: %s\n"
    (match argv with first :: _ -> first | [] -> "<empty>");
  Printf.printf "argv_command: %s\n"
    (match argv with _ :: second :: _ -> second | _ -> "<none>");
  Printf.printf "argv_has_filename: %b\n" (List.mem "-filename" argv);
  begin match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Find.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some evidence ->
          Printf.printf
            "returned=%d total=%d stale_skipped=%d offset=%d status=%s index=%s\n"
            (Find.Output.returned_count evidence)
            (Find.Output.total_count evidence)
            (Find.Output.stale_skipped evidence)
            (Find.Output.offset evidence)
            (status_text (Find.Output.status evidence))
            (index_status_text (Find.Output.index_status evidence));
          print_endline
            (List.hd (String.split_on_char '\n' (Tool.Output.text output))))
  end;
  [%expect
    {|
    permissions: 3
    status: completed
    argv_program: fake-ocamlmerlin
    argv_selector: single
    argv_command: occurrences
    argv_has_filename: true
    returned=1 total=2 stale_skipped=1 offset=1 status=complete index=unknown
    OCaml references for lib/a.ml:1:4 |}]

let%expect_test "malformed merlin position surfaces a decode error" =
  with_project @@ fun ~root ~fs ~workspace ->
  let run_with start =
    let merlin = write_fake_merlin_start root ~start in
    let tool = Find.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
    let input =
      json_obj
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 1);
          ("column", Json.int 4);
        ]
    in
    print_status (Tool.Call.run (decode_call tool input) ())
  in
  (* Non-integer member, absent member, and an out-of-range value exercise both
     of_json error branches: the "must contain line and col" message and the
     Position.make validation message. *)
  run_with {|{"line":"x","col":4}|};
  run_with {|{"col":4}|};
  run_with {|{"line":0,"col":4}|};
  [%expect
    {|
    status: failed failed: unexpected ocamlmerlin response: position object must contain line and col
    status: failed failed: unexpected ocamlmerlin response: position object must contain line and col
    status: failed failed: unexpected ocamlmerlin response: Spice_ocaml.Position.make: line must be >= 1 |}]

let%expect_test "include stale and limit are explicit" =
  with_project @@ fun ~root ~fs ~workspace ->
  let merlin, _log = write_fake_merlin root in
  let tool = Find.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("include_stale", Json.bool true);
        ("limit", Json.int 1);
      ]
  in
  let result = Tool.Call.run (decode_call tool input) () in
  print_status result;
  begin match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Find.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some evidence -> (
          Printf.printf
            "returned=%d total=%d stale_skipped=%d offset=%d status=%s \
             truncated=%b index=%s\n"
            (Find.Output.returned_count evidence)
            (Find.Output.total_count evidence)
            (Find.Output.stale_skipped evidence)
            (Find.Output.offset evidence)
            (status_text (Find.Output.status evidence))
            (Tool.Output.truncated output)
            (index_status_text (Find.Output.index_status evidence));
          match Find.Output.next evidence with
          | None -> print_endline "next: none"
          | Some next ->
              Printf.printf "next: offset=%s\n"
                (match Find.Input.offset next with
                | None -> "-"
                | Some offset -> string_of_int offset)))
  end;
  [%expect
    {|
    status: completed
    returned=1 total=2 stale_skipped=0 offset=1 status=partial truncated=true index=unknown
    next: offset=2 |}]

[%%run_tests "spice.tools.ocaml_find_references.expect"]
