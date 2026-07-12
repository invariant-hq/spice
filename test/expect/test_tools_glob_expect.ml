(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Glob = Spice_tools.Glob
module Json = Jsont.Json
module Tool = Spice_tool
module Workspace = Spice_workspace

let sandbox = Spice_sandbox.seal Spice_sandbox.Policy.direct

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

let write_disk ?mtime file contents =
  mkdir_p (Filename.dirname file);
  let oc = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc contents;
      flush oc);
  match mtime with None -> () | Some time -> Unix.utimes file time time

let with_temp_dir f =
  let dir = Filename.temp_file "spice-glob-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  let outside = Filename.temp_file "spice-glob-outside-" ".tmp" in
  Fun.protect
    ~finally:(fun () -> rm_rf outside)
    (fun () ->
      write_disk (path root ".env") "A=1\n";
      write_disk (path root ".gitignore") "ignored.txt\nignored_dir/\n";
      write_disk ~mtime:10. (path root ".hidden/tool.ml") "let hidden = ()\n";
      write_disk (path root "docs/readme.md") "# docs\n";
      write_disk (path root "file_root.txt") "not a directory\n";
      write_disk (path root "ignored.txt") "ignored\n";
      write_disk (path root "ignored_dir/secret.ml") "let ignored = ()\n";
      write_disk ~mtime:20. (path root "lib/alpha.ml") "let alpha = ()\n";
      write_disk ~mtime:30. (path root "lib/beta.ml") "let beta = ()\n";
      write_disk ~mtime:40. (path root "lib/same_a.ml") "let same_a = ()\n";
      write_disk ~mtime:40. (path root "lib/same_b.ml") "let same_b = ()\n";
      write_disk (path root "notes.txt") "notes\n";
      write_disk ~mtime:50. (path root "src/app.ml") "let app = ()\n";
      write_disk (path root ".git/config") "metadata\n";
      write_disk (path root ".git/secret.ml") "let secret = ()\n";
      write_disk (path root "nested/.svn/secret.ml") "let svn = ()\n";
      write_disk outside "outside\n";
      Unix.symlink "lib" (path root "lib_link");
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env -> f ~outside ~fs:(Eio.Stdenv.fs env) ~workspace)

let option_int = function None -> "-" | Some n -> string_of_int n

let sort = function
  | Glob.Input.Path -> "path"
  | Glob.Input.Modified -> "modified"

let status = function
  | Glob.Output.Complete -> "complete"
  | Glob.Output.Partial Glob.Output.Limit -> "partial limit"

let next = function
  | None -> "none"
  | Some input ->
      Printf.sprintf "pattern=%s path=%s offset=%s limit=%s sort=%s"
        (Glob.Input.pattern input)
        (Option.value (Glob.Input.path input) ~default:"-")
        (option_int (Glob.Input.offset input))
        (option_int (Glob.Input.limit input))
        (sort (Glob.Input.sort input))

let paths_text paths =
  match paths with
  | [] -> "-"
  | paths -> String.concat " " (List.map Workspace.Path.display paths)

let take n items =
  let rec loop acc n = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | item :: items -> loop (item :: acc) (n - 1) items
  in
  loop [] n items

let print_output output =
  Printf.printf "query: pattern=%S root=%s sort=%s\n"
    (Glob.Output.pattern output)
    (Workspace.Path.display (Glob.Output.root output))
    (sort (Glob.Output.sort output));
  Printf.printf
    "page: returned=%d total=%d offset=%d limit=%d status=%s has_more=%b next=%s\n"
    (Glob.Output.returned_files output)
    (Glob.Output.total_files output)
    (Glob.Output.offset output)
    (Glob.Output.limit output)
    (status (Glob.Output.status output))
    (Glob.Output.has_more output)
    (next (Glob.Output.next output));
  Printf.printf "files: %s\n" (paths_text (Glob.Output.files output))

let normalize_message ?outside message =
  let message =
    if String.starts_with ~prefix:"rg: error parsing glob" message then
      "rg: error parsing glob <normalized>"
    else message
  in
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

let run ~fs ~workspace ?outside input =
  Glob.run ~sandbox ~fs ~workspace input |> print_result ?outside

let print_decode label json =
  let result =
    match Glob.Input.decode json with
    | Error _ -> "error"
    | Ok input ->
        Printf.sprintf "ok pattern=%s path=%s offset=%s limit=%s sort=%s"
          (Glob.Input.pattern input)
          (Option.value (Glob.Input.path input) ~default:"-")
          (option_int (Glob.Input.offset input))
          (option_int (Glob.Input.limit input))
          (sort (Glob.Input.sort input))
    | exception Invalid_argument message -> "exception " ^ message
  in
  Printf.printf "%s: %s\n" label result

let print_invalid_constructor label f =
  match f () with
  | _ -> Printf.printf "%s: accepted\n" label
  | exception Invalid_argument message ->
      Printf.printf "%s: invalid %s\n" label message

let json_member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | _ -> None

let%expect_test "input contract" =
  print_decode "minimal" (json_obj [ ("pattern", Json.string "**/*.ml") ]);
  print_decode "full"
    (json_obj
       [
         ("pattern", Json.string "**/*.ml");
         ("path", Json.string "lib");
         ("offset", Json.int 3);
         ("limit", Json.int 4);
         ("sort", Json.string "modified");
       ]);
  print_decode "empty json path"
    (json_obj [ ("pattern", Json.string "**/*.ml"); ("path", Json.string "") ]);
  print_decode "unknown field"
    (json_obj
       [ ("pattern", Json.string "**/*.ml"); ("recursive", Json.bool true) ]);
  print_decode "bad sort"
    (json_obj
       [ ("pattern", Json.string "**/*.ml"); ("sort", Json.string "size") ]);
  print_decode "bad offset"
    (json_obj [ ("pattern", Json.string "**/*.ml"); ("offset", Json.int 0) ]);
  print_decode "bad limit"
    (json_obj [ ("pattern", Json.string "**/*.ml"); ("limit", Json.int 0) ]);
  print_invalid_constructor "empty pattern" (fun () -> Glob.Input.make "");
  print_invalid_constructor "empty path" (fun () ->
      Glob.Input.make ~path:"" "**/*.ml");
  print_invalid_constructor "offset zero" (fun () ->
      Glob.Input.make ~offset:0 "**/*.ml");
  print_invalid_constructor "limit over max" (fun () ->
      Glob.Input.make ~limit:(Glob.max_limit + 1) "**/*.ml");
  print_invalid_constructor "pattern NUL" (fun () ->
      Glob.Input.make "bad\000pattern");
  [%expect
    {|
    minimal: ok pattern=**/*.ml path=- offset=- limit=- sort=path
    full: ok pattern=**/*.ml path=lib offset=3 limit=4 sort=modified
    empty json path: ok pattern=**/*.ml path=- offset=- limit=- sort=path
    unknown field: error
    bad sort: error
    bad offset: error
    bad limit: error
    empty pattern: invalid pattern must not be empty
    empty path: invalid path must not be empty
    offset zero: invalid offset must be at least 1
    limit over max: invalid limit must be at most 1000
    pattern NUL: invalid pattern must not contain NUL |}]

let%expect_test "path and modified sorting" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "path";
  run ~fs ~workspace (Glob.Input.make "**/*.ml");
  print_case "modified";
  run ~fs ~workspace (Glob.Input.make ~sort:Glob.Input.Modified "**/*.ml");
  [%expect
    {|
    -- path --
    query: pattern="**/*.ml" root=. sort=path
    page: returned=6 total=6 offset=1 limit=100 status=complete has_more=false next=none
    files: .hidden/tool.ml lib/alpha.ml lib/beta.ml lib/same_a.ml lib/same_b.ml src/app.ml
    -- modified --
    query: pattern="**/*.ml" root=. sort=modified
    page: returned=6 total=6 offset=1 limit=100 status=complete has_more=false next=none
    files: src/app.ml lib/same_a.ml lib/same_b.ml lib/beta.ml lib/alpha.ml .hidden/tool.ml |}]

let%expect_test "dotfiles ignored files and protected metadata" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "dotfile";
  run ~fs ~workspace (Glob.Input.make ".env");
  print_case "ignored file";
  run ~fs ~workspace (Glob.Input.make "ignored.txt");
  print_case "ignored directory";
  run ~fs ~workspace (Glob.Input.make "ignored_dir/**");
  print_case "protected vcs";
  run ~fs ~workspace (Glob.Input.make "**/secret.ml");
  [%expect
    {|
    -- dotfile --
    query: pattern=".env" root=. sort=path
    page: returned=1 total=1 offset=1 limit=100 status=complete has_more=false next=none
    files: .env
    -- ignored file --
    query: pattern="ignored.txt" root=. sort=path
    page: returned=0 total=0 offset=1 limit=100 status=complete has_more=false next=none
    files: -
    -- ignored directory --
    query: pattern="ignored_dir/**" root=. sort=path
    page: returned=0 total=0 offset=1 limit=100 status=complete has_more=false next=none
    files: -
    -- protected vcs --
    query: pattern="**/secret.ml" root=. sort=path
    page: returned=0 total=0 offset=1 limit=100 status=complete has_more=false next=none
    files: - |}]

let%expect_test "pagination and structured continuation" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "first page";
  let result =
    Glob.run ~sandbox ~fs ~workspace
      (Glob.Input.make ~path:"lib" ~limit:2 "**/*.ml")
  in
  print_result result;
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "glob returned no output"
  in
  let next_json =
    match Tool.Output.json (Glob.Output.encode output) with
    | Some json -> (
        match json_member "next" json with
        | Some next -> next
        | None -> failf "output JSON has no next field")
    | None -> failf "output has no JSON"
  in
  print_case "next json";
  begin match Glob.Input.decode next_json with
  | Ok input -> Printf.printf "next: %s\n" (next (Some input))
  | Error error -> Printf.printf "decode error: %s\n" error
  end;
  print_case "final page";
  run ~fs ~workspace (Glob.Input.make ~path:"lib" ~offset:3 ~limit:2 "**/*.ml");
  print_case "past eof";
  run ~fs ~workspace (Glob.Input.make ~path:"lib" ~offset:99 ~limit:2 "**/*.ml");
  [%expect
    {|
    -- first page --
    query: pattern="**/*.ml" root=lib sort=path
    page: returned=2 total=4 offset=1 limit=2 status=partial limit has_more=true next=pattern=**/*.ml path=lib offset=3 limit=2 sort=path
    files: lib/alpha.ml lib/beta.ml
    -- next json --
    next: pattern=**/*.ml path=lib offset=3 limit=2 sort=path
    -- final page --
    query: pattern="**/*.ml" root=lib sort=path
    page: returned=2 total=4 offset=3 limit=2 status=complete has_more=false next=none
    files: lib/same_a.ml lib/same_b.ml
    -- past eof --
    query: pattern="**/*.ml" root=lib sort=path
    page: returned=0 total=4 offset=99 limit=2 status=complete has_more=false next=none
    files: - |}]

let%expect_test "unsafe roots and invalid glob fail" =
  with_fixture @@ fun ~outside ~fs ~workspace ->
  let cases =
    [
      ("bad glob", Glob.Input.make "[", None);
      ("missing", Glob.Input.make ~path:"missing" "**/*.ml", None);
      ("file path", Glob.Input.make ~path:"file_root.txt" "**/*.ml", None);
      ("symlink root", Glob.Input.make ~path:"lib_link" "**/*.ml", None);
      ( "outside workspace",
        Glob.Input.make ~path:outside "**/*.ml",
        Some outside );
    ]
  in
  List.iter
    (fun (label, input, outside) ->
      print_case label;
      run ~fs ~workspace ?outside input)
    cases;
  [%expect
    {|
    -- bad glob --
    failed invalid_input: rg: error parsing glob <normalized>
    -- missing --
    failed not_found: missing: path does not exist
    -- file path --
    failed invalid_input: file_root.txt: not a directory
    -- symlink root --
    failed invalid_input: lib_link: symlink search roots are not supported
    -- outside workspace --
    failed invalid_input: path is outside workspace: <outside> |}]

let%expect_test "erased adapter permissions output and cancellation" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "adapter";
  let tool = Glob.tool ~sandbox ~fs ~workspace () in
  let call =
    match
      Tool.Call.decode [ tool ] ~name:Glob.name
        ~input:
          (json_obj
             [
               ("pattern", Json.string "**/*.ml");
               ("path", Json.string "lib");
               ("limit", Json.int 2);
             ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  begin match (Tool.Result.status result, Tool.Result.output result) with
  | Tool.Result.Completed, Some output ->
      let lines = String.split_on_char '\n' (Tool.Output.text output) in
      List.iter print_endline (take 4 lines);
      let json_next =
        match Tool.Output.json output with
        | Some json -> (
            match json_member "next" json with
            | Some next_json -> (
                match Glob.Input.decode next_json with
                | Ok input -> next (Some input)
                | Error error -> "decode error: " ^ error)
            | None -> "missing")
        | None -> "missing json"
      in
      Printf.printf "next JSON: %s\n" json_next;
      Printf.printf "truncated=%b\n" (Tool.Output.truncated output)
  | _ -> failf "adapter call did not complete"
  end;
  print_case "cancelled";
  Glob.run ~sandbox ~fs ~workspace
    ~cancelled:(fun () -> true)
    (Glob.Input.make "**/*.ml")
  |> print_result;
  [%expect
    {|
    -- adapter --
    permissions: 1
    pattern="**/*.ml" root=lib files=2/4 offset=1 limit=2 sort=path status=partial
    lib/alpha.ml
    lib/beta.ml
    next: glob {"pattern":"**/*.ml","path":"lib","offset":3,"limit":2,"sort":"path"}
    next JSON: pattern=**/*.ml path=lib offset=3 limit=2 sort=path
    truncated=false
    -- cancelled --
    interrupted cancelled=true: tool call cancelled |}]

let%expect_test "sandbox refusal prevents ripgrep spawn" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  let refusing =
    Spice_sandbox.seal
      (Spice_sandbox.Policy.confined ~reads:Spice_sandbox.Policy.All
         ~writable_roots:[] ~protected_meta:[] ~protected_paths:[]
         ~network:Spice_sandbox.Policy.Network.Restricted)
  in
  Glob.run ~sandbox:refusing ~fs ~workspace (Glob.Input.make "**/*.ml")
  |> print_result;
  [%expect {| failed unavailable: no sandbox backend configured |}]

[%%run_tests "spice.tools.glob.expect"]
