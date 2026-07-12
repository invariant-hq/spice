(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Rename = Spice_tools.Ocaml_rename
module Json = Jsont.Json
module Tool = Spice_tool
module Workspace = Spice_workspace
module Receipt = Spice_tools.Receipt

let sandbox = Spice_sandbox.seal Spice_sandbox.Policy.direct

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
  let dir = Filename.temp_file "spice-ocaml-rename-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f (Unix.realpath dir))

let with_workspace f =
  with_temp_dir @@ fun root ->
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env -> f ~root ~fs:(Eio.Stdenv.fs env) ~workspace

(* A fake ocamlmerlin that emits a fixed [value] JSON array of occurrences. It
   hard-fails when the mandatory [single] selector is missing, drains stdin, and
   ignores everything else. *)
let write_fake_merlin root ~value =
  let script = path root "fake-ocamlmerlin" in
  write_disk script
    (Printf.sprintf
       {|#!/bin/sh
if [ "$1" != "single" ]; then
  printf 'fake-ocamlmerlin: missing single selector in: %%s\n' "$*" >&2
  exit 3
fi
cat >/dev/null
printf '%%s\n' %S
|}
       (Printf.sprintf {|{"class":"return","value":%s,"notifications":[]}|}
          value));
  Unix.chmod script 0o755;
  script

(* A fake ocamlmerlin that fails loudly if ever invoked: proves the pure
   pre-Merlin checks short-circuit before any occurrence query. *)
let write_never_merlin root =
  let script = path root "never-ocamlmerlin" in
  write_disk script
    "#!/bin/sh\nprintf 'never-ocamlmerlin: must not run\\n' >&2\nexit 7\n";
  Unix.chmod script 0o755;
  script

let occ ~file ~sl ~sc ~el ~ec ~stale =
  Printf.sprintf
    {|{"file":%s,"start":{"line":%d,"col":%d},"end":{"line":%d,"col":%d},"stale":%b}|}
    (Printf.sprintf "%S" file) sl sc el ec stale

let occ_array occs = "[" ^ String.concat "," occs ^ "]"

let decode_call tool input =
  match Tool.Call.decode [ tool ] ~name:Rename.name ~input () with
  | Ok call -> call
  | Error error -> failf "decode failed: %a" Tool.Error.pp error

let prepare_call call =
  match Tool.Call.prepare call () with
  | None -> failf "rename call was not staged"
  | Some preparation -> (
      match Tool.Call.prepared_outcome call preparation with
      | None -> failf "rename preparation did not belong to its call"
      | Some outcome -> outcome)

let run_call call =
  match prepare_call call with
  | Tool.Preparation.Finished result -> result
  | Tool.Preparation.Prepared { execution; _ } -> Tool.Execution.run execution ()

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
  match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Rename.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some ev ->
          let plan = Rename.Output.plan ev in
          Printf.printf "rename: %s -> %s applied=%b total=%d files=%d\n"
            (Rename.Plan.old_name plan)
            (Rename.Plan.new_name plan)
            (Rename.Output.applied ev)
            (Rename.Plan.total_occurrences plan)
            (List.length (Rename.Plan.targets plan));
          List.iter
            (fun target ->
              Printf.printf "  target %s occurrences=%d\n"
                (Workspace.Path.display (Rename.Target.path target))
                (Rename.Target.occurrences target))
            (Rename.Plan.targets plan);
          let receipt = Rename.Output.receipt ev in
          Printf.printf "  receipt empty=%b paths=[%s]\n"
            (Receipt.is_empty receipt)
            (String.concat ";"
               (List.map Workspace.Path.display (Receipt.paths receipt))))

let print_decode label json =
  match Rename.Input.decode json with
  | Ok input ->
      let position = Rename.Input.position input in
      Printf.printf "%s: ok %s %d:%d new=%s dry=%b max=%d\n" label
        (Rename.Input.path input)
        (Spice_ocaml.Position.line position)
        (Spice_ocaml.Position.column position)
        (Rename.Input.new_name input)
        (Rename.Input.dry_run input)
        (Rename.Input.max_occurrences input)
  | Error message -> Printf.printf "%s: error %s\n" label message

let%expect_test "input contract" =
  print_decode "minimal"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("new_name", Json.string "goal");
       ]);
  print_decode "full"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 2);
         ("column", Json.int 10);
         ("new_name", Json.string "goal");
         ("dry_run", Json.bool true);
         ("max_occurrences", Json.int 42);
       ]);
  print_decode "missing new_name"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
       ]);
  print_decode "unknown field"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("new_name", Json.string "goal");
         ("scope", Json.string "renaming");
       ]);
  print_decode "max out of range"
    (json_obj
       [
         ("path", Json.string "lib/a.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("new_name", Json.string "goal");
         ("max_occurrences", Json.int 5000);
       ]);
  [%expect
    {|
    minimal: ok lib/a.ml 1:4 new=goal dry=false max=200
    full: ok lib/a.ml 2:10 new=goal dry=true max=42
    missing new_name: error Missing member new_name in ocaml_rename input object
    unknown field: error Unexpected member scope for ocaml_rename input object
    max out of range: error max_occurrences exceeds 1000 |}]

let%expect_test "multi-file rename dry run then apply" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\nlet use = target + 1\n";
  write_disk (path root "lib/b.ml") "let z = A.target\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:10 ~stale:false;
        occ ~file:(path root "lib/a.ml") ~sl:2 ~sc:10 ~el:2 ~ec:16 ~stale:false;
        occ ~file:(path root "lib/b.ml") ~sl:1 ~sc:10 ~el:1 ~ec:16 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let base =
    [
      ("path", Json.string "lib/a.ml");
      ("line", Json.int 1);
      ("column", Json.int 4);
      ("new_name", Json.string "goal");
    ]
  in
  print_endline "== dry run ==";
  let dry =
    run_call
      (decode_call tool (json_obj (base @ [ ("dry_run", Json.bool true) ])))
  in
  print_status dry;
  print_output dry;
  Printf.printf "a.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/a.ml"))
       "let target = 1\nlet use = target + 1\n");
  print_endline "== apply ==";
  let applied = run_call (decode_call tool (json_obj base)) in
  print_status applied;
  print_output applied;
  Printf.printf "a.ml=%S\n" (read_disk (path root "lib/a.ml"));
  Printf.printf "b.ml=%S\n" (read_disk (path root "lib/b.ml"));
  [%expect
    {|
    == dry run ==
    status: completed
    rename: target -> goal applied=false total=3 files=2
      target lib/a.ml occurrences=2
      target lib/b.ml occurrences=1
      receipt empty=true paths=[]
    a.ml unchanged=true
    == apply ==
    status: completed
    rename: target -> goal applied=true total=3 files=2
      target lib/a.ml occurrences=2
      target lib/b.ml occurrences=1
      receipt empty=false paths=[lib/a.ml;lib/b.ml]
    a.ml="let goal = 1\nlet use = goal + 1\n"
    b.ml="let z = A.goal\n" |}]

let%expect_test "ml and mli pair" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let f = 1\n";
  write_disk (path root "lib/a.mli") "val f : int\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:5 ~stale:false;
        occ ~file:(path root "lib/a.mli") ~sl:1 ~sc:4 ~el:1 ~ec:5 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "g");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  print_output result;
  Printf.printf "a.ml=%S\n" (read_disk (path root "lib/a.ml"));
  Printf.printf "a.mli=%S\n" (read_disk (path root "lib/a.mli"));
  [%expect
    {|
    status: completed
    rename: f -> g applied=true total=2 files=2
      target lib/a.ml occurrences=1
      target lib/a.mli occurrences=1
      receipt empty=false paths=[lib/a.ml;lib/a.mli]
    a.ml="let g = 1\n"
    a.mli="val g : int\n" |}]

let%expect_test "record-field pun is refused" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/p.ml") "let x = 1\nlet r = { x }\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/p.ml") ~sl:1 ~sc:4 ~el:1 ~ec:5 ~stale:false;
        occ ~file:(path root "lib/p.ml") ~sl:2 ~sc:10 ~el:2 ~ec:11 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/p.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "y");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  Printf.printf "p.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/p.ml"))
       "let x = 1\nlet r = { x }\n");
  [%expect
    {|
    status: failed invalid_input: lib/p.ml:2:10 is a record-field pun; v1 does not rewrite label or pun sites, edit it manually
    p.ml unchanged=true |}]

let%expect_test "labelled argument is refused" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/l.ml") "let x = 1\nlet use = f ~x\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/l.ml") ~sl:1 ~sc:4 ~el:1 ~ec:5 ~stale:false;
        occ ~file:(path root "lib/l.ml") ~sl:2 ~sc:13 ~el:2 ~ec:14 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/l.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "y");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  Printf.printf "l.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/l.ml"))
       "let x = 1\nlet use = f ~x\n");
  [%expect
    {|
    status: failed invalid_input: lib/l.ml:2:13 is a labelled-argument occurrence (~/?); v1 does not rewrite label or pun sites, edit it manually
    l.ml unchanged=true |}]

let%expect_test "stale occurrence is refused" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\nlet use = target + 1\n";
  let value =
    occ_array
      [ occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:10 ~stale:true ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "goal");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  Printf.printf "a.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/a.ml"))
       "let target = 1\nlet use = target + 1\n");
  [%expect
    {|
    status: failed stale: index appears stale: 1 occurrence(s) skipped; rebuild with dune build @ocaml-index and retry
    a.ml unchanged=true |}]

let%expect_test "range text mismatch is refused as stale" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\nlet use = other1 + 1\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:10 ~stale:false;
        occ ~file:(path root "lib/a.ml") ~sl:2 ~sc:10 ~el:2 ~ec:16 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "goal");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  Printf.printf "a.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/a.ml"))
       "let target = 1\nlet use = other1 + 1\n");
  [%expect
    {|
    status: failed stale: lib/a.ml:2:10 no longer holds "target" (found "other1"); rebuild the project index with dune build @ocaml-index and retry
    a.ml unchanged=true |}]

let%expect_test "invalid new name" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\n";
  let never = write_never_merlin root in
  let tool = Rename.tool ~sandbox ~program:[ never ] ~fs ~workspace () in
  let call new_name =
    let input =
      json_obj
        [
          ("path", Json.string "lib/a.ml");
          ("line", Json.int 1);
          ("column", Json.int 4);
          ("new_name", Json.string new_name);
        ]
    in
    Printf.printf "new_name=%s -> " new_name;
    print_status (run_call (decode_call tool input))
  in
  call "match";
  call "Target";
  call "target";
  [%expect
    {|
    new_name=match -> status: failed invalid_input: new name "match" is an OCaml keyword
    new_name=Target -> status: failed invalid_input: new name "Target" is a constructor or module identifier but the entity is a value identifier
    new_name=target -> status: failed invalid_input: new name "target" is the same as the current name |}]

let%expect_test "occurrence count over cap is failed" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\nlet use = target + 1\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:10 ~stale:false;
        occ ~file:(path root "lib/a.ml") ~sl:2 ~sc:10 ~el:2 ~ec:16 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "goal");
        ("max_occurrences", Json.int 1);
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  Printf.printf "a.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/a.ml"))
       "let target = 1\nlet use = target + 1\n");
  [%expect
    {|
    status: failed failed: 2 occurrences exceed the rename cap 1; the rename is too large to apply safely as one edit
    a.ml unchanged=true |}]

let%expect_test "zero occurrences is invalid_input" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\n";
  let merlin = write_fake_merlin root ~value:(occ_array []) in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "goal");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  [%expect
    {|
    status: failed invalid_input: no renameable binding at lib/a.ml:1:4; the cursor may not be on an identifier, or the project index is missing (dune build @ocaml-index) |}]

let%expect_test "not a standalone identifier is refused" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\nlet use = targeted + 1\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:10 ~stale:false;
        (* This range holds "target" but sits inside the token "targeted". *)
        occ ~file:(path root "lib/a.ml") ~sl:2 ~sc:10 ~el:2 ~ec:16 ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let input =
    json_obj
      [
        ("path", Json.string "lib/a.ml");
        ("line", Json.int 1);
        ("column", Json.int 4);
        ("new_name", Json.string "goal");
      ]
  in
  let result = run_call (decode_call tool input) in
  print_status result;
  Printf.printf "a.ml unchanged=%b\n"
    (String.equal
       (read_disk (path root "lib/a.ml"))
       "let target = 1\nlet use = targeted + 1\n");
  [%expect
    {|
    status: failed invalid_input: lib/a.ml:2:10 is not a standalone identifier; the local parse cannot corroborate the rename here, edit it manually
    a.ml unchanged=true |}]

let%expect_test "permissions dry versus apply" =
  with_workspace @@ fun ~root ~fs ~workspace ->
  write_disk (path root "lib/a.ml") "let target = 1\n";
  write_disk (path root "lib/b.ml") "let use = A.target\n";
  let value =
    occ_array
      [
        occ ~file:(path root "lib/a.ml") ~sl:1 ~sc:4 ~el:1 ~ec:10
          ~stale:false;
        occ ~file:(path root "lib/b.ml") ~sl:1 ~sc:12 ~el:1 ~ec:18
          ~stale:false;
      ]
  in
  let merlin = write_fake_merlin root ~value in
  let tool = Rename.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let base =
    [
      ("path", Json.string "lib/a.ml");
      ("line", Json.int 1);
      ("column", Json.int 4);
      ("new_name", Json.string "goal");
    ]
  in
  let dry =
    decode_call tool (json_obj (base @ [ ("dry_run", Json.bool true) ]))
  in
  let apply = decode_call tool (json_obj base) in
  Printf.printf "dry: %d requests\n" (List.length (Tool.Call.permissions dry));
  Printf.printf "apply preliminary: %d requests\n"
    (List.length (Tool.Call.permissions apply));
  (match prepare_call dry with
  | Tool.Preparation.Finished _ -> print_endline "dry final: none"
  | Tool.Preparation.Prepared _ -> failf "dry run unexpectedly prepared a write");
  (match prepare_call apply with
  | Tool.Preparation.Finished result ->
      print_status result;
      failf "apply preparation unexpectedly finished"
  | Tool.Preparation.Prepared { permissions; _ } ->
      Printf.printf "apply final: %d request\n" (List.length permissions);
      List.concat_map Spice_permission.Request.accesses permissions
      |> List.iter (fun access ->
          match access with
          | Spice_permission.Access.Path
              {
                op = `Modify;
                scope =
                  Spice_permission.Access.Path_scope.Workspace { relative; _ };
              } ->
              Printf.printf "  modify %s\n" (Spice_path.Rel.to_string relative)
          | _ ->
              failf "unexpected final rename access: %a"
                Spice_permission.Access.pp access));
  [%expect {|
    dry: 2 requests
    apply preliminary: 2 requests
    dry final: none
    apply final: 1 request
      modify lib/a.ml
      modify lib/b.ml |}]

[%%run_tests "spice.tools.ocaml_rename.expect"]
