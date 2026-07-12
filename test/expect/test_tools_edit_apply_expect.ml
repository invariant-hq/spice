(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Apply_patch = Spice_tools.Apply_patch
module Anchor = Spice_tools.Anchor
module Edit_file = Spice_tools.Edit_file
module Edit_lines = Spice_tools.Edit_lines
module Json = Jsont.Json
module Read_file = Spice_tools.Read_file
module Tool = Spice_tool
module Workspace = Spice_workspace

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_member name json =
  match Json.decode (Jsont.mem name Jsont.json) json with
  | Ok value -> Some value
  | Error _ -> None

let json_list json =
  match Json.decode (Jsont.list Jsont.json) json with
  | Ok items -> Some items
  | Error _ -> None

let json_string json =
  match Json.decode Jsont.string json with
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
  let dir = Filename.temp_file "spice-edit-apply-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  let outside = Filename.temp_file "spice-edit-apply-outside-" ".txt" in
  Fun.protect
    ~finally:(fun () -> rm_rf outside)
    (fun () ->
      write_disk (path root "note.txt") "alpha\nbravo\ncharlie\n";
      write_disk (path root "repeat.txt") "red\nred\nblue\n";
      write_disk (path root "crlf.txt") "one\r\ntwo\r\nthree\r\n";
      write_disk (path root "bom-crlf.txt") "\239\187\191alpha\r\nbravo\r\n";
      write_disk (path root "source.txt") "line1\nline2\nline3\n";
      write_disk (path root "move.txt") "old\nkeep\n";
      write_disk (path root "delete.txt") "remove me\n";
      write_disk (path root "bad.bin") "text\000payload\n";
      write_disk (path root "bad-utf8.txt") "\255\254\n";
      write_disk (path root "parent-file") "not a directory\n";
      write_disk outside "secret\n";
      Unix.mkdir (path root "dir") 0o755;
      Unix.symlink "note.txt" (path root "link_note.txt");
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env ->
      f ~root ~outside ~fs:(Eio.Stdenv.fs env) ~workspace)

let identity_summary_string value =
  match String.split_on_char ':' value with
  | algorithm :: _hex :: length :: _ -> algorithm ^ ":" ^ length
  | value -> String.concat ":" value

let test_identity_string =
  Spice_digest.Identity.to_string (Spice_digest.Identity.of_contents "seen")

let read_identity ~fs ~workspace path =
  match
    Tool.Result.output
      (Read_file.run ~fs ~workspace (Read_file.Input.make path))
  with
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

let edit_output_json output =
  match Tool.Output.json (Edit_file.Output.encode output) with
  | Some json -> json
  | None -> failf "edit_file output did not encode JSON"

let edit_status output =
  let json = edit_output_json output in
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
  Option.bind (json_member "stale_check" (edit_output_json output)) json_string
  |> Option.value ~default:"unknown"

let print_edit_output output =
  let occurrence =
    match Edit_file.Output.occurrence output with
    | Edit_file.Input.Once -> "once"
    | Edit_file.Input.All -> "all"
  in
  Printf.printf "path: %s\n"
    (Workspace.Path.display (Edit_file.Output.path output));
  Printf.printf "status: %s replacements=%d occurrence=%s stale=%s edit=%b\n"
    (edit_status output)
    (Edit_file.Output.replacements output)
    occurrence (stale_check output)
    (not (Spice_tools.Receipt.is_empty (Edit_file.Output.receipt output)));
  Printf.printf "after: %S\n" (Edit_file.Output.after_contents output)

let normalize_message ?outside message =
  match outside with
  | None -> message
  | Some outside -> String.replace_all ~sub:outside ~by:"<outside>" message

let print_result ?outside print_output result =
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

let run_edit ~fs ~workspace ?max_bytes ?cancelled ?outside input =
  Edit_file.run ~fs ~workspace ?max_file_bytes:max_bytes ?cancelled input
  |> print_result ?outside print_edit_output

let print_disk root rel =
  let file = path root rel in
  let exists = Sys.file_exists file in
  let regular = exists && not (Sys.is_directory file) in
  if regular then Printf.printf "disk %s: %S\n" rel (read_disk file)
  else
    Printf.printf "disk %s: %s\n" rel
      (if exists then "<non-file>" else "<missing>")

let edit_input ?occurrence ?if_identity ~path ~old_string ~new_string () =
  Edit_file.Input.replace ~path ~old_string ~new_string ?occurrence ?if_identity
    ()

let print_edit_decode label json =
  let status =
    match Edit_file.Input.decode json with
    | Error _ -> "error"
    | Ok input ->
        let occurrence =
          match Edit_file.Input.occurrence input with
          | Edit_file.Input.Once -> "once"
          | Edit_file.Input.All -> "all"
        in
        Printf.sprintf "ok path=%s occurrence=%s if=%b"
          (Edit_file.Input.path input)
          occurrence
          (Option.is_some (Edit_file.Input.if_identity input))
  in
  Printf.printf "%s: %s\n" label status

let print_edit_constructor label f =
  let status =
    match f () with
    | input ->
        let occurrence =
          match Edit_file.Input.occurrence input with
          | Edit_file.Input.Once -> "once"
          | Edit_file.Input.All -> "all"
        in
        Printf.sprintf "ok path=%s occurrence=%s"
          (Edit_file.Input.path input)
          occurrence
    | exception Invalid_argument message -> "error " ^ message
  in
  Printf.printf "%s: %s\n" label status

let patch lines =
  String.concat "\n" (("*** Begin Patch" :: lines) @ [ "*** End Patch"; "" ])

let apply_input patch =
  match Apply_patch.Input.make ~patch with
  | Ok input -> input
  | Error message -> failf "invalid patch input: %s" message

let print_apply_decode label json =
  let status =
    match Apply_patch.Input.decode json with
    | Error _ -> "error"
    | Ok input ->
        Printf.sprintf "ok ops=%d"
          (List.length (Apply_patch.Input.operations input))
  in
  Printf.printf "%s: %s\n" label status

let print_apply_constructor label patch =
  let status =
    match Apply_patch.Input.make ~patch with
    | Ok input ->
        Printf.sprintf "ok ops=%d"
          (List.length (Apply_patch.Input.operations input))
    | Error _ -> "error"
  in
  Printf.printf "%s: %s\n" label status

let print_edit_lines_decode label json =
  let status =
    match Edit_lines.Input.decode json with
    | Error _ -> "error"
    | Ok input ->
        Printf.sprintf "ok path=%s edits=%d"
          (Edit_lines.Input.path input)
          (List.length (Edit_lines.Input.edits input))
  in
  Printf.printf "%s: %s\n" label status

let print_edit_lines_constructor label f =
  let status =
    match f () with
    | input ->
        Printf.sprintf "ok path=%s edits=%d"
          (Edit_lines.Input.path input)
          (List.length (Edit_lines.Input.edits input))
    | exception Invalid_argument message -> "error " ^ message
  in
  Printf.printf "%s: %s\n" label status

let apply_kind = function
  | Apply_patch.Output.Create -> "create"
  | Apply_patch.Output.Modify -> "modify"
  | Apply_patch.Output.Delete -> "delete"
  | Apply_patch.Output.Move { from } ->
      "move from " ^ Workspace.Path.display from

let print_apply_output output =
  let entries =
    Apply_patch.Output.entries output
    |> List.map (fun entry ->
        Workspace.Path.display (Apply_patch.Output.path entry)
        ^ ":"
        ^ apply_kind (Apply_patch.Output.kind entry))
  in
  Printf.printf "entries: %s\n" (String.concat " " entries);
  Printf.printf "entries=%d diff=%b\n"
    (List.length (Apply_patch.Output.entries output))
    (not (String.is_empty (Apply_patch.Output.diff output)))

let print_apply_receipt output =
  let receipt = Apply_patch.Output.receipt output in
  Printf.printf "receipt changes=%d concrete=%d\n"
    (List.length (Spice_tools.Receipt.changes receipt))
    (List.length (Spice_tools.Receipt.paths receipt))

let run_apply ~fs ~workspace ?max_bytes ?cancelled ?outside input =
  Apply_patch.run ~fs ~workspace ?max_file_bytes:max_bytes ?cancelled input
  |> print_result ?outside print_apply_output

let json_list_length name json =
  match Option.bind (json_member name json) json_list with
  | Some items -> string_of_int (List.length items)
  | None -> "missing"

let json_string_list name json =
  match Option.bind (json_member name json) json_list with
  | Some items -> items |> List.filter_map json_string |> String.concat ","
  | None -> "missing"

let%expect_test "input contracts validate decoded and constructed requests" =
  let valid_patch =
    patch
      [
        "*** Add File: new.txt";
        "+hello";
        "*** Update File: source.txt";
        "@@";
        "-line2";
        "+LINE2";
      ]
  in
  print_edit_decode "edit minimal"
    (json_obj
       [
         ("path", Json.string "note.txt");
         ("old_string", Json.string "alpha");
         ("new_string", Json.string "ALPHA");
       ]);
  print_edit_decode "edit all identity"
    (json_obj
       [
         ("path", Json.string "repeat.txt");
         ("old_string", Json.string "red");
         ("new_string", Json.string "green");
         ("occurrence", Json.string "all");
         ("if_identity", Json.string test_identity_string);
       ]);
  print_edit_decode "edit unknown"
    (json_obj
       [
         ("path", Json.string "note.txt");
         ("old_string", Json.string "alpha");
         ("new_string", Json.string "ALPHA");
         ("extra", Json.bool true);
       ]);
  print_edit_decode "edit binary"
    (json_obj
       [
         ("path", Json.string "note.txt");
         ("old_string", Json.string "a\000");
         ("new_string", Json.string "b");
       ]);
  print_edit_constructor "edit empty path" (fun () ->
      Edit_file.Input.replace ~path:"" ~old_string:"a" ~new_string:"b" ());
  print_edit_constructor "edit empty old" (fun () ->
      Edit_file.Input.replace ~path:"note.txt" ~old_string:"" ~new_string:"b" ());
  print_edit_constructor "edit same text" (fun () ->
      Edit_file.Input.replace ~path:"note.txt" ~old_string:"a" ~new_string:"a"
        ());
  print_edit_constructor "edit invalid utf8" (fun () ->
      Edit_file.Input.replace ~path:"note.txt" ~old_string:"\255"
        ~new_string:"b" ());
  print_apply_decode "patch valid"
    (json_obj [ ("patch", Json.string valid_patch) ]);
  print_apply_decode "patch unknown"
    (json_obj [ ("patch", Json.string valid_patch); ("extra", Json.bool true) ]);
  print_apply_constructor "patch empty" "";
  print_apply_constructor "patch escape"
    (patch [ "*** Add File: ../outside.txt"; "+nope" ]);
  print_edit_lines_decode "lines single replace"
    (json_obj
       [
         ("path", Json.string "note.txt");
         ( "edits",
           Json.list
             [
               json_obj
                 [
                   ("op", Json.string "replace");
                   ("anchor", Json.string "AppleBanana§alpha");
                   ("end_anchor", Json.string "AppleBanana§alpha");
                   ("text", Json.string "ALPHA");
                 ];
             ] );
       ]);
  print_edit_lines_decode "lines replace missing end"
    (json_obj
       [
         ("path", Json.string "note.txt");
         ( "edits",
           Json.list
             [
               json_obj
                 [
                   ("op", Json.string "replace");
                   ("anchor", Json.string "AppleBanana§alpha");
                   ("text", Json.string "ALPHA");
                 ];
             ] );
       ]);
  print_edit_lines_constructor "lines typed single replace" (fun () ->
      let anchor = Anchor.of_string "AppleBanana§alpha" in
      Edit_lines.Input.make ~path:"note.txt"
        ~edits:
          [
            Edit_lines.Input.Edit.replace
              (Edit_lines.Input.Range.line anchor)
              ~text:"ALPHA";
          ]
        ());
  print_edit_lines_constructor "lines typed invalid anchor" (fun () ->
      let anchor = Anchor.of_string "\255" in
      Edit_lines.Input.make ~path:"note.txt"
        ~edits:
          [
            Edit_lines.Input.Edit.replace
              (Edit_lines.Input.Range.line anchor)
              ~text:"ALPHA";
          ]
        ());
  [%expect
    {|
    edit minimal: ok path=note.txt occurrence=once if=false
    edit all identity: ok path=repeat.txt occurrence=all if=true
    edit unknown: error
    edit binary: error
    edit empty path: error path must not be empty
    edit empty old: error old_string must not be empty
    edit same text: error old_string and new_string must differ
    edit invalid utf8: error old_string must be valid UTF-8
    patch valid: ok ops=2
    patch unknown: error
    patch empty: error
    patch escape: error
    lines single replace: ok path=note.txt edits=1
    lines replace missing end: error
    lines typed single replace: ok path=note.txt edits=1
    lines typed invalid anchor: error anchor must be valid UTF-8 |}]

let%expect_test "edit_file replacement identity and normalization behavior" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  print_case "exact replacement";
  let identity = read_identity ~fs ~workspace "note.txt" in
  run_edit ~fs ~workspace
    (edit_input ~path:"note.txt" ~old_string:"bravo" ~new_string:"BRAVO"
       ~if_identity:identity ());
  print_disk root "note.txt";
  print_case "replace all";
  run_edit ~fs ~workspace
    (edit_input ~path:"repeat.txt" ~old_string:"red" ~new_string:"green"
       ~occurrence:Edit_file.Input.All ());
  print_disk root "repeat.txt";
  print_case "stale identity";
  write_disk (path root "note.txt") "external\n";
  run_edit ~fs ~workspace
    (edit_input ~path:"note.txt" ~old_string:"BRAVO" ~new_string:"beta"
       ~if_identity:identity ());
  print_disk root "note.txt";
  print_case "bom crlf";
  run_edit ~fs ~workspace
    (edit_input ~path:"bom-crlf.txt" ~old_string:"alpha\nbravo\n"
       ~new_string:"alpha\nBRAVO\n" ());
  print_disk root "bom-crlf.txt";
  print_case "crlf normalized no-op";
  run_edit ~fs ~workspace
    (edit_input ~path:"crlf.txt" ~old_string:"one\ntwo\n"
       ~new_string:"one\r\ntwo\r\n" ());
  print_disk root "crlf.txt";
  print_case "multiple matches";
  run_edit ~fs ~workspace
    (edit_input ~path:"repeat.txt" ~old_string:"green" ~new_string:"red" ());
  [%expect
    {|
    -- exact replacement --
    path: note.txt
    status: modify sha256:20 -> sha256:20 replacements=1 occurrence=once stale=fresh edit=true
    after: "alpha\nBRAVO\ncharlie\n"
    disk note.txt: "alpha\nBRAVO\ncharlie\n"
    -- replace all --
    path: repeat.txt
    status: modify sha256:13 -> sha256:17 replacements=2 occurrence=all stale=not_checked edit=true
    after: "green\ngreen\nblue\n"
    disk repeat.txt: "green\ngreen\nblue\n"
    -- stale identity --
    failed stale: note.txt: stale file identity
    disk note.txt: "external\n"
    -- bom crlf --
    path: bom-crlf.txt
    status: modify sha256:17 -> sha256:17 replacements=1 occurrence=once stale=not_checked edit=true
    after: "\239\187\191alpha\r\nBRAVO\r\n"
    disk bom-crlf.txt: "\239\187\191alpha\r\nBRAVO\r\n"
    -- crlf normalized no-op --
    path: crlf.txt
    status: unchanged sha256:17 replacements=1 occurrence=once stale=not_checked edit=false
    after: "one\r\ntwo\r\nthree\r\n"
    disk crlf.txt: "one\r\ntwo\r\nthree\r\n"
    -- multiple matches --
    failed invalid_input: repeat.txt: old_string matched 2 times; provide more context or set occurrence=all |}]

let%expect_test "edit_file rejects unsafe targets without mutation" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let outside_path = outside in
  let cases =
    [
      ( "symlink",
        edit_input ~path:"link_note.txt" ~old_string:"alpha" ~new_string:"ALPHA"
          (),
        None );
      ( "binary",
        edit_input ~path:"bad.bin" ~old_string:"text" ~new_string:"TEXT" (),
        None );
      ( "invalid utf8",
        edit_input ~path:"bad-utf8.txt" ~old_string:"x" ~new_string:"y" (),
        None );
      ( "too large",
        edit_input ~path:"note.txt" ~old_string:"alpha" ~new_string:"ALPHA" (),
        Some 3 );
      ( "escape",
        edit_input ~path:outside_path ~old_string:"secret" ~new_string:"public"
          (),
        None );
    ]
  in
  List.iter
    (fun (label, input, max_bytes) ->
      print_case label;
      run_edit ~fs ~workspace ?max_bytes ~outside input)
    cases;
  print_case "unchanged";
  print_disk root "note.txt";
  print_disk root "bad.bin";
  [%expect
    {|
    -- symlink --
    failed invalid_input: link_note.txt: symlink targets are not supported
    -- binary --
    failed invalid_input: bad.bin: binary file
    -- invalid utf8 --
    failed invalid_input: bad-utf8.txt: not valid UTF-8 text
    -- too large --
    failed invalid_input: note.txt: file is too large (20 bytes, max 3)
    -- escape --
    failed invalid_input: path is outside workspace: <outside>
    -- unchanged --
    disk note.txt: "alpha\nbravo\ncharlie\n"
    disk bad.bin: "text\000payload\n" |}]

let%expect_test "apply_patch applies add update delete and move" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let input =
    apply_input
      (patch
         [
           "*** Add File: new/dir/created.txt";
           "+hello";
           "+world";
           "*** Update File: source.txt";
           "@@";
           "-line2";
           "+LINE2";
           "*** Delete File: delete.txt";
           "*** Update File: move.txt";
           "*** Move to: moved/path.txt";
           "@@";
           "-old";
           "+new";
         ])
  in
  let result = Apply_patch.run ~fs ~workspace input in
  print_result print_apply_output result;
  print_disk root "new/dir/created.txt";
  print_disk root "source.txt";
  print_disk root "delete.txt";
  print_disk root "move.txt";
  print_disk root "moved/path.txt";
  begin match Tool.Result.output result with
  | Some output -> (
      match Tool.Output.json (Apply_patch.Output.encode output) with
      | Some json ->
          Printf.printf "json paths=%s changed=%s dirs=%s diff=%b\n"
            (json_list_length "paths" json)
            (json_list_length "changed_files" json)
            (json_string_list "created_directories" json)
            (Option.is_some (json_member "diff" json))
      | None -> print_endline "json missing")
  | None -> print_endline "output missing"
  end;
  [%expect
    {|
    entries: new/dir/created.txt:create source.txt:modify delete.txt:delete moved/path.txt:move from move.txt
    entries=4 diff=true
    disk new/dir/created.txt: "hello\nworld\n"
    disk source.txt: "line1\nLINE2\nline3\n"
    disk delete.txt: <missing>
    disk move.txt: <missing>
    disk moved/path.txt: "new\nkeep\n"
    json paths=4 changed=4 dirs=new,new/dir,moved diff=true |}]

let%expect_test "apply_patch preserves BOM and CRLF line endings" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let input =
    apply_input
      (patch [ "*** Update File: bom-crlf.txt"; "@@"; "-alpha"; "+ALPHA" ])
  in
  run_apply ~fs ~workspace input;
  print_disk root "bom-crlf.txt";
  [%expect
    {|
    entries: bom-crlf.txt:modify
    entries=1 diff=true
    disk bom-crlf.txt: "\239\187\191ALPHA\r\nbravo\r\n" |}]

let%expect_test "apply_patch plans delete then add as one replacement" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let input =
    apply_input
      (patch
         [
           "*** Delete File: delete.txt";
           "*** Add File: delete.txt";
           "+replacement";
         ])
  in
  let result = Apply_patch.run ~fs ~workspace input in
  print_result
    (fun output ->
      print_apply_output output;
      print_apply_receipt output)
    result;
  print_disk root "delete.txt";
  [%expect
    {|
    entries: delete.txt:modify
    entries=1 diff=true
    receipt changes=1 concrete=1
    disk delete.txt: "replacement\n" |}]

let%expect_test "apply_patch plans repeated updates against virtual contents" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let input =
    apply_input
      (patch
         [
           "*** Update File: source.txt";
           "@@";
           "-line2";
           "+LINE2";
           "*** Update File: source.txt";
           "@@";
           "-LINE2";
           "+final";
         ])
  in
  let result = Apply_patch.run ~fs ~workspace input in
  print_result
    (fun output ->
      print_apply_output output;
      print_apply_receipt output)
    result;
  print_disk root "source.txt";
  [%expect
    {|
    entries: source.txt:modify
    entries=1 diff=true
    receipt changes=1 concrete=1
    disk source.txt: "line1\nfinal\nline3\n" |}]

let%expect_test "apply_patch collapses move chains to the original source" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let input =
    apply_input
      (patch
         [
           "*** Update File: move.txt";
           "*** Move to: intermediate.txt";
           "@@";
           "-old";
           "+new";
           "*** Update File: intermediate.txt";
           "*** Move to: chained/path.txt";
           "@@";
           "-keep";
           "+kept";
         ])
  in
  let result = Apply_patch.run ~fs ~workspace input in
  print_result
    (fun output ->
      print_apply_output output;
      print_apply_receipt output)
    result;
  print_disk root "move.txt";
  print_disk root "intermediate.txt";
  print_disk root "chained/path.txt";
  [%expect
    {|
    entries: chained/path.txt:move from move.txt
    entries=1 diff=true
    receipt changes=1 concrete=2
    disk move.txt: <missing>
    disk intermediate.txt: <missing>
    disk chained/path.txt: "new\nkept\n" |}]

let%expect_test "apply_patch diagnoses contradictory sequential operations" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let cases =
    [
      ( "add then add",
        patch
          [ "*** Add File: dup.txt"; "+one"; "*** Add File: dup.txt"; "+two" ]
      );
      ( "add then move output",
        patch
          [
            "*** Add File: staged.txt";
            "+occupied";
            "*** Update File: move.txt";
            "*** Move to: staged.txt";
            "@@";
            "-old";
            "+new";
          ] );
      ( "move then update source",
        patch
          [
            "*** Update File: move.txt";
            "*** Move to: moved.txt";
            "@@";
            "-old";
            "+new";
            "*** Update File: move.txt";
            "@@";
            "-keep";
            "+kept";
          ] );
    ]
  in
  List.iter
    (fun (label, patch) ->
      print_case label;
      run_apply ~fs ~workspace (apply_input patch))
    cases;
  print_case "unchanged";
  print_disk root "move.txt";
  print_disk root "dup.txt";
  print_disk root "staged.txt";
  print_disk root "moved.txt";
  [%expect
    {|
    -- add then add --
    failed invalid_input: dup.txt: operation 2 (Add) conflicts with operation 1 (Add): expected missing, found text
    -- add then move output --
    failed invalid_input: staged.txt: operation 2 (Move) conflicts with operation 1 (Add): expected missing, found text
    -- move then update source --
    failed invalid_input: move.txt: operation 2 (Update) conflicts with operation 1 (Move): expected text, found missing
    -- unchanged --
    disk move.txt: "old\nkeep\n"
    disk dup.txt: <missing>
    disk staged.txt: <missing>
    disk moved.txt: <missing> |}]

let%expect_test
    "apply_patch rejects duplicate outputs missing context and unsafe reads" =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  let cases =
    [
      ( "missing context",
        apply_input
          (patch [ "*** Update File: source.txt"; "@@"; "-absent"; "+present" ]),
        None );
      ( "existing add destination",
        apply_input (patch [ "*** Add File: note.txt"; "+replacement" ]),
        None );
      ( "existing move destination",
        apply_input
          (patch
             [
               "*** Update File: move.txt";
               "*** Move to: note.txt";
               "@@";
               "-old";
               "+new";
             ]),
        None );
      ( "symlink",
        apply_input
          (patch [ "*** Update File: link_note.txt"; "@@"; "-alpha"; "+ALPHA" ]),
        None );
      ( "binary",
        apply_input
          (patch [ "*** Update File: bad.bin"; "@@"; "-text"; "+TEXT" ]),
        None );
      ( "invalid utf8",
        apply_input
          (patch [ "*** Update File: bad-utf8.txt"; "@@"; "-x"; "+y" ]),
        None );
      ( "too large",
        apply_input
          (patch [ "*** Update File: source.txt"; "@@"; "-line1"; "+LINE1" ]),
        Some 3 );
    ]
  in
  List.iter
    (fun (label, input, max_bytes) ->
      print_case label;
      run_apply ~fs ~workspace ?max_bytes input)
    cases;
  print_case "unchanged";
  print_disk root "source.txt";
  print_disk root "dup.txt";
  [%expect
    {|
    -- missing context --
    failed invalid_input: source.txt: patch chunk 0 failed: missing lines: "absent"
    -- existing add destination --
    failed invalid_input: note.txt: expected missing, found text
    -- existing move destination --
    failed invalid_input: note.txt: expected missing, found text
    -- symlink --
    failed invalid_input: link_note.txt: symlink targets are not supported
    -- binary --
    failed invalid_input: bad.bin: binary file
    -- invalid utf8 --
    failed invalid_input: bad-utf8.txt: not valid UTF-8 text
    -- too large --
    failed invalid_input: source.txt: file is too large (18 bytes, max 3)
    -- unchanged --
    disk source.txt: "line1\nline2\nline3\n"
    disk dup.txt: <missing> |}]

let%expect_test
    "erased adapters expose permissions output and cancellation is pre-mutation"
    =
  with_fixture @@ fun ~root ~outside:_ ~fs ~workspace ->
  print_case "edit adapter";
  let edit_tool = Edit_file.tool ~fs ~workspace () in
  let edit_call =
    match
      Tool.Call.decode [ edit_tool ] ~name:Edit_file.name
        ~input:
          (json_obj
             [
               ("path", Json.string "note.txt");
               ("old_string", Json.string "alpha");
               ("new_string", Json.string "ALPHA");
             ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode edit adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n"
    (List.length (Tool.Call.permissions edit_call));
  begin match Tool.Call.run edit_call () |> Tool.Result.output with
  | Some output ->
      Printf.printf "text_prefix=%b json=%b truncated=%b\n"
        (String.starts_with ~prefix:"modify: note.txt replacements=1"
           (Tool.Output.text output))
        (Option.is_some (Tool.Output.json output))
        (Tool.Output.truncated output)
  | None -> failf "edit adapter returned no output"
  end;
  print_case "apply adapter";
  let apply_tool = Apply_patch.tool ~fs ~workspace () in
  let apply_call =
    match
      Tool.Call.decode [ apply_tool ] ~name:Apply_patch.name
        ~input:
          (json_obj
             [
               ( "patch",
                 Json.string (patch [ "*** Add File: adapter.txt"; "+adapter" ])
               );
             ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode apply adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n"
    (List.length (Tool.Call.permissions apply_call));
  begin match Tool.Call.run apply_call () |> Tool.Result.output with
  | Some output ->
      let first_line =
        match String.split_on_char '\n' (Tool.Output.text output) with
        | line :: _ -> line
        | [] -> failf "apply adapter output text was unexpectedly empty"
      in
      Printf.printf "text=%s json=%b truncated=%b\n" first_line
        (Option.is_some (Tool.Output.json output))
        (Tool.Output.truncated output)
  | None -> failf "apply adapter returned no output"
  end;
  print_case "edit cancelled before apply";
  let edit_cancel_calls = ref 0 in
  let edit_cancelled () =
    incr edit_cancel_calls;
    !edit_cancel_calls > 1
  in
  run_edit ~fs ~workspace ~cancelled:edit_cancelled
    (edit_input ~path:"source.txt" ~old_string:"line1" ~new_string:"LINE1" ());
  print_disk root "source.txt";
  print_case "apply cancelled after parents";
  let apply_cancel_calls = ref 0 in
  let apply_cancelled () =
    incr apply_cancel_calls;
    !apply_cancel_calls > 2
  in
  run_apply ~fs ~workspace ~cancelled:apply_cancelled
    (apply_input
       (patch [ "*** Add File: cancelled/child.txt"; "+not written" ]));
  print_disk root "cancelled";
  print_disk root "cancelled/child.txt";
  [%expect
    {|
    -- edit adapter --
    permissions: 1
    text_prefix=true json=true truncated=false
    -- apply adapter --
    permissions: 1
    text=Success. Updated the following files: json=true truncated=false
    -- edit cancelled before apply --
    interrupted cancelled=true: tool call cancelled
    disk source.txt: "line1\nline2\nline3\n"
    -- apply cancelled after parents --
    interrupted cancelled=true: tool call cancelled
    disk cancelled: <missing>
    disk cancelled/child.txt: <missing> |}]

[%%run_tests "spice.tools.edit_apply.expect"]
