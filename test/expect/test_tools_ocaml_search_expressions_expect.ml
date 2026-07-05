(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Json = Jsont.Json
module Search = Spice_tools.Ocaml_search_expressions
module Ocaml = Spice_ocaml
module Tool = Spice_tool
module Workspace = Spice_workspace

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

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

let with_temp_dir f =
  let dir = Filename.temp_file "spice-ocaml-search-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  write_disk (path root "broken.ml") "let x =\n";
  write_disk (path root "junk.ml") "\000\000not ocaml\n";
  write_disk (path root "lib/util.ml")
    "let ys = List.filter pred xs\nlet zs = List.map f xs\n";
  write_disk (path root "notes.txt") "List.filter in prose\n";
  write_disk (path root "src/app.ml")
    "let picked =\n\
    \  List.filter\n\
    \    is_ready\n\
    \    items\n\n\
     let fallback o = match o with None -> 0 | Some v -> v\n";
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env -> f ~fs:(Eio.Stdenv.fs env) ~workspace

let option_int = function None -> "-" | Some n -> string_of_int n

let status = function
  | Search.Output.Complete -> "complete"
  | Search.Output.Partial Search.Output.Limit -> "partial limit"

let next = function
  | None -> "none"
  | Some input ->
      Printf.sprintf "paths=%s offset=%s limit=%s"
        (match Search.Input.paths input with
        | None -> "-"
        | Some paths -> String.concat "," paths)
        (option_int (Search.Input.offset input))
        (option_int (Search.Input.limit input))

let paths_text paths =
  match paths with
  | [] -> "-"
  | paths -> String.concat " " (List.map Workspace.Path.display paths)

let line_text (line : Search.Output.line) =
  Printf.sprintf "%d:%s%s" line.Search.Output.number line.Search.Output.text
    (if line.Search.Output.truncated then ":truncated" else "")

let finding_text (finding : Search.Output.finding) =
  let location = finding.Search.Output.location in
  Printf.sprintf "%s [%s]"
    (Format.asprintf "%a" Ocaml.Location.pp location)
    (String.concat "; " (List.map line_text finding.Search.Output.lines))

let skipped_text (skipped : Search.Output.skipped) =
  let reason =
    match skipped.Search.Output.reason with
    | Search.Output.Binary -> "binary"
    | Search.Output.Invalid_utf8 -> "invalid_utf8"
    | Search.Output.Too_large -> "too_large"
    | Search.Output.Syntax_error message -> "syntax_error(" ^ message ^ ")"
    | Search.Output.Read_error message -> "read_error(" ^ message ^ ")"
  in
  Printf.sprintf "%s:%s"
    (Workspace.Path.display skipped.Search.Output.skipped_path)
    reason

let print_output output =
  Printf.printf "query: pattern=%S roots=%s\n"
    (Search.Output.pattern output)
    (paths_text (Search.Output.roots output));
  Printf.printf
    "page: returned=%d total=%d offset=%d limit=%d status=%s has_more=%b \
     next=%s searched=%d\n"
    (Search.Output.returned_results output)
    (Search.Output.total_results output)
    (Search.Output.offset output)
    (Search.Output.limit output)
    (status (Search.Output.status output))
    (Search.Output.has_more output)
    (next (Search.Output.next output))
    (Search.Output.searched_files output);
  begin match Search.Output.skipped output with
  | [] -> ()
  | skipped ->
      Printf.printf "skipped: %s\n"
        (String.concat " " (List.map skipped_text skipped))
  end;
  Printf.printf "findings: %s\n"
    (match Search.Output.findings output with
    | [] -> "-"
    | findings -> String.concat " | " (List.map finding_text findings))

let print_result result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some output -> print_output output
      | None -> print_endline "completed without output")
  | Tool.Result.Failed { kind; message; metadata = _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason

let run ~fs ~workspace input = Search.run ~fs ~workspace input |> print_result

let%expect_test "structural search, coverage evidence, and paging" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "workspace";
  run ~fs ~workspace (Search.Input.make "List.filter __ __");
  print_case "clause set";
  run ~fs ~workspace
    (Search.Input.make "match __ with None -> __ | Some __1 -> __1");
  print_case "paged";
  run ~fs ~workspace (Search.Input.make ~limit:1 "List.filter __ __");
  print_case "file root";
  run ~fs ~workspace
    (Search.Input.make ~paths:[ "lib/util.ml" ] "List.filter __ __");
  [%expect
    {|
    -- workspace --
    query: pattern="List.filter __ __" roots=.
    page: returned=2 total=2 offset=1 limit=100 status=complete has_more=false next=none searched=2
    skipped: broken.ml:syntax_error(syntax error at line 2, column 0) junk.ml:binary
    findings: lib/util.ml:1:9-1:28 [1:let ys = List.filter pred xs] | src/app.ml:2:2-4:9 [2:  List.filter; 3:    is_ready; 4:    items]
    -- clause set --
    query: pattern="match __ with None -> __ | Some __1 -> __1" roots=.
    page: returned=1 total=1 offset=1 limit=100 status=complete has_more=false next=none searched=2
    skipped: broken.ml:syntax_error(syntax error at line 2, column 0) junk.ml:binary
    findings: src/app.ml:6:17-6:53 [6:let fallback o = match o with None -> 0 | Some v -> v]
    -- paged --
    query: pattern="List.filter __ __" roots=.
    page: returned=1 total=2 offset=1 limit=1 status=partial limit has_more=true next=paths=. offset=2 limit=1 searched=2
    skipped: broken.ml:syntax_error(syntax error at line 2, column 0) junk.ml:binary
    findings: lib/util.ml:1:9-1:28 [1:let ys = List.filter pred xs]
    -- file root --
    query: pattern="List.filter __ __" roots=lib/util.ml
    page: returned=1 total=1 offset=1 limit=100 status=complete has_more=false next=none searched=1
    findings: lib/util.ml:1:9-1:28 [1:let ys = List.filter pred xs] |}]

let%expect_test "invalid patterns and roots fail loudly" =
  with_fixture @@ fun ~fs ~workspace ->
  let cases =
    [
      ("type constraint", Search.Input.make "(__ : int)");
      ("syntax error", Search.Input.make "let x");
      ("missing root", Search.Input.make ~paths:[ "missing" ] "List.filter");
    ]
  in
  List.iter
    (fun (label, input) ->
      print_case label;
      run ~fs ~workspace input)
    cases;
  [%expect
    {|
    -- type constraint --
    failed invalid_input: type-constrained expression (e : t) is not supported: type-constrained patterns require a typed backend
    -- syntax error --
    failed invalid_input: the query is not a valid OCaml expression
    -- missing root --
    failed not_found: missing: path does not exist |}]

let%expect_test "input decode" =
  let print_decode label json =
    let result =
      match Search.Input.decode json with
      | Error _ -> "error"
      | Ok input ->
          Printf.sprintf "ok pattern=%s paths=%s offset=%s limit=%s"
            (Search.Input.pattern input)
            (match Search.Input.paths input with
            | None -> "-"
            | Some paths -> String.concat "," paths)
            (option_int (Search.Input.offset input))
            (option_int (Search.Input.limit input))
    in
    Printf.printf "%s: %s\n" label result
  in
  print_decode "minimal" (json_obj [ ("pattern", Json.string "__ + 1") ]);
  print_decode "full"
    (json_obj
       [
         ("pattern", Json.string "List.map __ __");
         ("paths", Json.list [ Json.string "lib" ]);
         ("offset", Json.int 2);
         ("limit", Json.int 5);
       ]);
  print_decode "unknown field"
    (json_obj [ ("pattern", Json.string "x"); ("glob", Json.string "*.ml") ]);
  print_decode "empty pattern" (json_obj [ ("pattern", Json.string "") ]);
  [%expect
    {|
    minimal: ok pattern=__ + 1 paths=- offset=- limit=-
    full: ok pattern=List.map __ __ paths=lib offset=2 limit=5
    unknown field: error
    empty pattern: error |}]

let%expect_test "erased tool adapter and cancellation" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "adapter";
  let tool =
    Search.tool ~fs ~workspace ~render:(Search.Output.anchored ()) ()
  in
  let call =
    match
      Tool.Call.decode [ tool ] ~name:Search.name
        ~input:
          (json_obj
             [
               ("pattern", Json.string "List.filter __ __");
               ("paths", Json.list [ Json.string "src" ]);
             ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  begin match Tool.Result.output result with
  | Some output -> print_string (Tool.Output.text output)
  | None -> failf "adapter returned no output"
  end;
  print_case "cancelled";
  let calls = ref 0 in
  let cancelled () =
    incr calls;
    !calls > 1
  in
  Search.run ~fs ~workspace ~cancelled (Search.Input.make "List.filter")
  |> print_result;
  [%expect
    {|
    -- adapter --
    permissions: 1
    ocaml_search_expressions pattern="List.filter __ __" results=1/1 offset=1 limit=100 status=complete searched_files=1
    src/app.ml:2:2-4:9
      2 #4587a344772c:   List.filter
      3 #c5c7e770fd8d:     is_ready
      4 #cf158a5eb2fc:     items
    -- cancelled --
    interrupted cancelled=true: tool call cancelled |}]

[%%run_tests "spice.tools.ocaml_search_expressions.expect"]
