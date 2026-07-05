(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Json = Jsont.Json
module Read_file = Spice_tools.Read_file
module Tool = Spice_tool
module Workspace = Spice_workspace
module Write_file = Spice_tools.Write_file

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_member name json =
  match Json.decode (Jsont.mem name Jsont.json) json with
  | Ok value -> Some value
  | Error _ -> None

let json_string json =
  match Json.decode Jsont.string json with
  | Ok value -> Some value
  | Error _ -> None

let json_string_list json =
  match Json.decode (Jsont.list Jsont.string) json with
  | Ok value -> Some value
  | Error _ -> None

let print_case name = Printf.printf "-- %s --\n" name

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
  let dir = Filename.temp_file "spice-write-file-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  let outside = Filename.temp_file "spice-write-file-outside-" ".txt" in
  Fun.protect
    ~finally:(fun () -> rm_rf outside)
    (fun () ->
      write_disk (path root "note.txt") "alpha\n";
      write_disk (path root "bom.txt") "\239\187\191alpha\n";
      write_disk (path root "bad.bin") "text\000payload\n";
      write_disk (path root "bad-utf8.txt") "\255\254\n";
      write_disk (path root "parent-file") "not a directory\n";
      write_disk outside "secret\n";
      Unix.mkdir (path root "dir") 0o755;
      Unix.symlink "note.txt" (path root "link_note.txt");
      Unix.symlink "dir" (path root "link_parent");
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env ->
      f ~root ~outside ~fs:(Eio.Stdenv.fs env) ~workspace)

let identity_summary identity =
  match String.split_on_char ':' (Spice_digest.Identity.to_string identity) with
  | algorithm :: _hex :: length :: _ -> algorithm ^ ":" ^ length
  | value -> String.concat ":" value

let test_identity_string =
  Spice_digest.Identity.to_string (Spice_digest.Identity.of_contents "seen")

let write_create ~path ~contents =
  Write_file.Input.make ~path ~precondition:Write_file.Input.Missing ~contents

let write_replace ~path ~if_identity ~contents =
  Write_file.Input.make ~path
    ~precondition:(Write_file.Input.Identity if_identity) ~contents

let identity_summary_string value =
  match String.split_on_char ':' value with
  | algorithm :: _hex :: length :: _ -> algorithm ^ ":" ^ length
  | value -> String.concat ":" value

let read_identity ~fs ~workspace path =
  let input = Read_file.Input.make path in
  match Tool.Result.output (Read_file.run ~fs ~workspace input) with
  | Some (Read_file.Output.Read read) -> (
      match read.Read_file.Output.status with
      | Read_file.Output.Complete identity -> identity
      | Read_file.Output.Partial _ ->
          failf "read_identity got a partial read for %s" path)
  | Some (Read_file.Output.Unchanged _) ->
      failf "read_identity got an unchanged read for %s" path
  | Some (Read_file.Output.Listing _) ->
      failf "read_identity got a directory listing for %s" path
  | None -> failf "read_identity got no output for %s" path

let output_json output =
  match Tool.Output.json (Write_file.Output.encode output) with
  | Some json -> json
  | None -> failf "write_file output did not encode JSON"

let created_directories output =
  let json = output_json output in
  let paths =
    Option.bind (json_member "created_directories" json) json_string_list
    |> Option.value ~default:[]
  in
  match paths with [] -> "-" | paths -> String.concat "," paths

let status output =
  let json = output_json output in
  let operation =
    Option.bind (json_member "operation" json) json_string
    |> Option.value ~default:"unknown"
  in
  let identity =
    Option.bind (json_member "identity" json) json_string
    |> Option.value ~default:""
  in
  match Option.bind (json_member "before_identity" json) json_string with
  | Some before ->
      Printf.sprintf "%s %s -> %s" operation
        (identity_summary_string before)
        (identity_summary_string identity)
  | None -> operation ^ " " ^ identity_summary_string identity

let stale_check output =
  Option.bind (json_member "stale_check" (output_json output)) json_string
  |> Option.value ~default:"unknown"

let print_output output =
  Printf.printf "path: %s\n"
    (Workspace.Path.display (Write_file.Output.path output));
  Printf.printf "status: %s stale=%s edit=%b dirs=%s\n" (status output)
    (stale_check output)
    (not (Spice_tools.Receipt.is_empty (Write_file.Output.receipt output)))
    (created_directories output);
  Printf.printf "contents: %S\n" (Write_file.Output.contents output)

let normalize_message ?outside message =
  match outside with
  | None -> message
  | Some outside -> String.replace_all ~sub:outside ~by:"<outside>" message

let print_result ?outside result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some output -> print_output output
      | None -> print_endline "completed without output")
  | Tool.Result.Failed { kind; message; metadata = _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        (normalize_message ?outside message)
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason

let run ~fs ~workspace ?max_bytes ?outside input =
  Write_file.run ~fs ~workspace ?max_file_bytes:max_bytes input
  |> print_result ?outside

let print_disk root rel =
  let file = path root rel in
  let exists = Sys.file_exists file in
  let regular = exists && not (Sys.is_directory file) in
  if regular then Printf.printf "disk: %S\n" (read_disk file)
  else Printf.printf "disk: %s\n" (if exists then "<non-file>" else "<missing>")

let print_mode root rel =
  let file = path root rel in
  match Unix.stat file with
  | stat -> Printf.printf "mode: %03o\n" (stat.Unix.st_perm land 0o777)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      Printf.printf "mode: <missing>\n"

let print_decode label json =
  let status =
    match Write_file.Input.decode json with
    | Error _ -> "error"
    | Ok input -> (
        match Write_file.Input.precondition input with
        | Write_file.Input.Missing ->
            "ok create path=" ^ Write_file.Input.path input
        | Write_file.Input.Identity identity ->
            "ok replace path="
            ^ Write_file.Input.path input
            ^ " identity=" ^ identity_summary identity)
  in
  Printf.printf "%s: %s\n" label status

let print_invalid_constructor label f =
  match f () with
  | _ -> Printf.printf "%s: accepted\n" label
  | exception Invalid_argument message ->
      Printf.printf "%s: invalid %s\n" label message

let%expect_test "input contract" =
  print_decode "create"
    (json_obj
       [ ("path", Json.string "new.txt"); ("contents", Json.string "hello\n") ]);
  print_decode "replace"
    (json_obj
       [
         ("path", Json.string "note.txt");
         ("contents", Json.string "bravo\n");
         ("if_identity", Json.string test_identity_string);
       ]);
  print_decode "unknown field"
    (json_obj
       [
         ("path", Json.string "new.txt");
         ("contents", Json.string "hello\n");
         ("extra", Json.bool true);
       ]);
  print_decode "binary contents"
    (json_obj
       [
         ("path", Json.string "new.txt"); ("contents", Json.string "hello\000\n");
       ]);
  print_invalid_constructor "empty path" (fun () ->
      write_create ~path:"" ~contents:"hello\n");
  print_invalid_constructor "invalid utf8" (fun () ->
      write_create ~path:"bad.txt" ~contents:"\255\254\n");
  [%expect
    {|
    create: ok create path=new.txt
    replace: ok replace path=note.txt identity=sha256:4
    unknown field: error
    binary contents: error
    empty path: invalid path must not be empty
    invalid utf8: invalid contents must be valid UTF-8 |}]

let%expect_test "create writes text and parent directories" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  print_case "create nested";
  run ~fs ~workspace
    (write_create ~path:"new/dir/file.txt" ~contents:"hello\nworld\n");
  print_disk root "new/dir/file.txt";
  [%expect
    {|
    -- create nested --
    path: new/dir/file.txt
    status: create sha256:12 stale=not_checked edit=true dirs=new,new/dir
    contents: "hello\nworld\n"
    disk: "hello\nworld\n" |}]

(* A replace precondition for a file that does not exist falls through to a
   create: there are no unseen contents for the identity guard to protect, and
   the reference tools are create-or-overwrite here. *)
let%expect_test "replace of a missing file creates it" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let fake_identity = Spice_digest.Identity.of_contents "seen" in
  run ~fs ~workspace
    (write_replace ~path:"missing.txt" ~if_identity:fake_identity
       ~contents:"new\n");
  print_disk root "missing.txt";
  [%expect
    {|
    path: missing.txt
    status: create sha256:4 stale=not_checked edit=true dirs=-
    contents: "new\n"
    disk: "new\n" |}]

let%expect_test "replace is identity-guarded and unchanged writes are no-ops" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let original = read_identity ~fs ~workspace "note.txt" in
  print_case "replace fresh";
  run ~fs ~workspace
    (write_replace ~path:"note.txt" ~if_identity:original ~contents:"bravo!\n");
  print_disk root "note.txt";
  let current = read_identity ~fs ~workspace "note.txt" in
  print_case "replace unchanged";
  run ~fs ~workspace
    (write_replace ~path:"note.txt" ~if_identity:current ~contents:"bravo!\n");
  print_disk root "note.txt";
  print_case "replace stale";
  write_disk (path root "note.txt") "external\n";
  run ~fs ~workspace
    (write_replace ~path:"note.txt" ~if_identity:current ~contents:"agent\n");
  print_disk root "note.txt";
  [%expect
    {|
    -- replace fresh --
    path: note.txt
    status: modify sha256:6 -> sha256:7 stale=fresh edit=true dirs=-
    contents: "bravo!\n"
    disk: "bravo!\n"
    -- replace unchanged --
    path: note.txt
    status: unchanged sha256:7 stale=fresh edit=false dirs=-
    contents: "bravo!\n"
    disk: "bravo!\n"
    -- replace stale --
    failed stale: note.txt: stale file identity
    disk: "external\n" |}]

let%expect_test "replace preserves an existing utf8 bom" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let identity = read_identity ~fs ~workspace "bom.txt" in
  run ~fs ~workspace
    (write_replace ~path:"bom.txt" ~if_identity:identity ~contents:"bravo\n");
  print_disk root "bom.txt";
  [%expect
    {|
    path: bom.txt
    status: modify sha256:9 -> sha256:9 stale=fresh edit=true dirs=-
    contents: "\239\187\191bravo\n"
    disk: "\239\187\191bravo\n" |}]

let%expect_test "replace preserves executable mode" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  Unix.chmod (path root "note.txt") 0o755;
  let identity = read_identity ~fs ~workspace "note.txt" in
  run ~fs ~workspace
    (write_replace ~path:"note.txt" ~if_identity:identity
       ~contents:"#!/bin/sh\necho ok\n");
  print_mode root "note.txt";
  [%expect
    {|
    path: note.txt
    status: modify sha256:6 -> sha256:18 stale=fresh edit=true dirs=-
    contents: "#!/bin/sh\necho ok\n"
    mode: 755 |}]

let%expect_test "failed create rolls back new parent directories" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let too_long = String.make 300 'x' in
  run ~fs ~workspace
    (write_create ~path:("rollback/" ^ too_long) ~contents:"new\n");
  print_disk root "rollback";
  [%expect
    {|
    failed failed: rollback/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: filesystem I/O error
    disk: <missing> |}]

let%expect_test "unsafe targets fail without mutation" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let identity = read_identity ~fs ~workspace "note.txt" in
  let fake_identity = Spice_digest.Identity.of_contents "seen" in
  let outside_path = outside in
  let cases =
    [
      ( "create existing file",
        write_create ~path:"note.txt" ~contents:"new\n",
        None );
      ( "create directory target",
        write_create ~path:"dir" ~contents:"new\n",
        None );
      ( "replace binary target",
        write_replace ~path:"bad.bin" ~if_identity:fake_identity
          ~contents:"new\n",
        None );
      ( "replace invalid utf8 target",
        write_replace ~path:"bad-utf8.txt" ~if_identity:fake_identity
          ~contents:"new\n",
        None );
      ( "create symlink target",
        write_create ~path:"link_note.txt" ~contents:"new\n",
        None );
      ( "create through symlink parent",
        write_create ~path:"link_parent/child.txt" ~contents:"new\n",
        None );
      ( "create through file parent",
        write_create ~path:"parent-file/child.txt" ~contents:"new\n",
        None );
      ( "create outside workspace",
        write_create ~path:outside_path ~contents:"new\n",
        None );
      ( "contents above max_bytes",
        write_create ~path:"too-big.txt" ~contents:"abcdef\n",
        Some 3 );
      ( "existing target above max_bytes",
        write_replace ~path:"note.txt" ~if_identity:identity ~contents:"new\n",
        Some 1 );
    ]
  in
  List.iter
    (fun (label, input, max_bytes) ->
      print_case label;
      run ~fs ~workspace ?max_bytes ~outside input)
    cases;
  print_case "unchanged after failures";
  print_disk root "note.txt";
  print_disk root "new.txt";
  print_disk root "too-big.txt";
  [%expect
    {|
    -- create existing file --
    failed invalid_input: note.txt: expected missing, found text
    -- create directory target --
    failed invalid_input: dir: expected missing, found other
    -- replace binary target --
    failed invalid_input: bad.bin: binary file
    -- replace invalid utf8 target --
    failed invalid_input: bad-utf8.txt: not valid UTF-8 text
    -- create symlink target --
    failed invalid_input: link_note.txt: expected missing, found other
    -- create through symlink parent --
    failed invalid_input: link_parent: symlink targets are not supported
    -- create through file parent --
    failed invalid_input: parent-file: not a directory
    -- create outside workspace --
    failed invalid_input: path is outside workspace: <outside>
    -- contents above max_bytes --
    failed invalid_input: too-big.txt: file is too large (7 bytes, max 3)
    -- existing target above max_bytes --
    failed invalid_input: note.txt: file is too large (6 bytes, max 1)
    -- unchanged after failures --
    disk: "alpha\n"
    disk: <missing>
    disk: <missing> |}]

let%expect_test "erased tool adapter and cancellation" =
  with_fixture @@ fun ~root:_ ~outside:_ ~fs ~workspace ->
  print_case "adapter";
  let tool = Write_file.tool ~fs ~workspace () in
  let call =
    match
      Tool.Call.decode [ tool ] ~name:Write_file.name
        ~input:
          (json_obj
             [
               ("path", Json.string "adapter.txt");
               ("contents", Json.string "adapter\n");
             ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  (match (Tool.Result.status result, Tool.Result.output result) with
  | Tool.Result.Completed, Some output ->
      Printf.printf "completed text_prefix=%b json=%b truncated=%b\n"
        (String.starts_with ~prefix:"create: adapter.txt identity=sha256:"
           (Tool.Output.text output))
        (Option.is_some (Tool.Output.json output))
        (Tool.Output.truncated output)
  | _ -> failf "adapter call did not complete");
  print_case "cancelled";
  Write_file.run ~fs ~workspace ~cancelled:(Fun.const true)
    (write_create ~path:"cancelled.txt" ~contents:"nope\n")
  |> print_result;
  [%expect
    {|
    -- adapter --
    permissions: 1
    completed text_prefix=true json=true truncated=false
    -- cancelled --
    interrupted cancelled=true: tool call cancelled |}]

[%%run_tests "spice.tools.write_file.expect"]
