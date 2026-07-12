(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Json = Jsont.Json
module Search_text = Spice_tools.Search_text
module Tool = Spice_tool
module Workspace = Spice_workspace

let environment =
  Spice_sandbox.Environment.make ~path:"/usr/bin:/bin"
    ~scratch:(Spice_path.Abs.of_string_exn "/tmp") ~user_names:[]
    ~launch:(Fun.const None)
  |> Result.get_ok

let sandbox =
  Spice_sandbox.seal (Spice_sandbox.Policy.direct ~environment)

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
  let dir = Filename.temp_file "spice-search-text-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  let outside = Filename.temp_file "spice-search-text-outside-" ".txt" in
  Fun.protect
    ~finally:(fun () -> rm_rf outside)
    (fun () ->
      write_disk (path root ".env") "alpha env\n";
      write_disk (path root "bad.bin") "alpha\000payload\n";
      write_disk (path root "bad-utf8.txt") "\255alpha\n";
      write_disk (path root "docs/readme.md") "Alpha heading\nplain text\n";
      write_disk (path root "ignored.txt") "alpha ignored\n";
      write_disk (path root "lib/util.ml")
        "let helper = \"alpha\"\nlet second = \"alpha\"\n";
      write_disk (path root "notes.txt") "nothing here\n";
      write_disk (path root "odd\n\".txt") "needle one\nneedle two\n";
      write_disk (path root "src/app.ml")
        "let alpha = 1\nlet beta = alpha + 1\nlet gamma = beta\n";
      write_disk (path root ".gitignore") "ignored.txt\n";
      write_disk (path root ".git/config") "alpha secret\n";
      write_disk outside "alpha outside\n";
      Unix.symlink "src" (path root "src_link");
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env -> f ~outside ~fs:(Eio.Stdenv.fs env) ~workspace)

let option_int = function None -> "-" | Some n -> string_of_int n

let input_mode = function
  | Search_text.Input.Files -> "files"
  | Search_text.Input.Count -> "count"
  | Search_text.Input.Matches -> "matches"

let input_case = function
  | Search_text.Input.Sensitive -> "sensitive"
  | Search_text.Input.Insensitive -> "insensitive"

let total = function
  | Search_text.Output.Exact n -> "exact " ^ string_of_int n
  | Search_text.Output.Lower_bound n -> "lower_bound " ^ string_of_int n
  | Search_text.Output.Unknown -> "unknown"

let status = function
  | Search_text.Output.Complete -> "complete"
  | Search_text.Output.Partial Search_text.Output.Limit -> "partial limit"

let next = function
  | None -> "none"
  | Some input ->
      Printf.sprintf "mode=%s paths=%s offset=%s limit=%s"
        (input_mode (Search_text.Input.mode input))
        (match Search_text.Input.paths input with
        | None -> "-"
        | Some paths -> String.concat "," paths)
        (option_int (Search_text.Input.offset input))
        (option_int (Search_text.Input.limit input))

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

let count_line (count : Search_text.Output.count) =
  Printf.sprintf "%s:%d"
    (Workspace.Path.display count.Search_text.Output.count_path)
    count.Search_text.Output.matching_lines

let line_kind = function
  | Search_text.Output.Match -> "match"
  | Search_text.Output.Context -> "context"

let line_text (line : Search_text.Output.line) =
  Printf.sprintf "%d:%s:%s%s" line.Search_text.Output.number
    (line_kind line.Search_text.Output.kind)
    line.Search_text.Output.text
    (if line.Search_text.Output.truncated then ":truncated" else "")

let span_text (span : Search_text.Output.span) =
  Printf.sprintf "%s [%s]"
    (Workspace.Path.display span.Search_text.Output.span_path)
    (String.concat "; " (List.map line_text span.Search_text.Output.lines))

let skipped_reason = function
  | Search_text.Output.Binary -> "binary"
  | Search_text.Output.Invalid_utf8 -> "invalid_utf8"

let skipped_text (skipped : Search_text.Output.skipped) =
  Printf.sprintf "%s:%s"
    (Workspace.Path.display skipped.Search_text.Output.skipped_path)
    (skipped_reason skipped.Search_text.Output.reason)

let print_output output =
  Printf.printf
    "query: pattern=%S roots=%s glob=%s mode=%s case=%s context=%d\n"
    (Search_text.Output.pattern output)
    (paths_text (Search_text.Output.roots output))
    (Option.value (Search_text.Output.glob output) ~default:"-")
    (input_mode (Search_text.Output.mode output))
    (input_case (Search_text.Output.case output))
    (Search_text.Output.context_lines output);
  Printf.printf
    "page: returned=%d total=%s offset=%d limit=%d status=%s has_more=%b next=%s\n"
    (Search_text.Output.returned_results output)
    (total (Search_text.Output.total_results output))
    (Search_text.Output.offset output)
    (Search_text.Output.limit output)
    (status (Search_text.Output.status output))
    (Search_text.Output.has_more output)
    (next (Search_text.Output.next output));
  begin match Search_text.Output.skipped output with
  | [] -> ()
  | skipped ->
      Printf.printf "skipped: %s\n"
        (String.concat " " (List.map skipped_text skipped))
  end;
  match Search_text.Output.result output with
  | Search_text.Output.Files paths ->
      Printf.printf "files: %s\n" (paths_text paths)
  | Search_text.Output.Count count ->
      Printf.printf "counts: %s\n"
        (match count.Search_text.Output.files with
        | [] -> "-"
        | files -> String.concat " " (List.map count_line files));
      Printf.printf "matching_lines: %s\n"
        (total count.Search_text.Output.total_matching_lines)
  | Search_text.Output.Matches spans ->
      Printf.printf "spans: %s\n"
        (match spans with
        | [] -> "-"
        | spans -> String.concat " | " (List.map span_text spans))

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

let run ~fs ~workspace ?outside input =
  Search_text.run ~sandbox ~fs ~workspace input |> print_result ?outside

let print_decode label json =
  let result =
    match Search_text.Input.decode json with
    | Error _ -> "error"
    | Ok input ->
        Printf.sprintf
          "ok pattern=%s mode=%s case=%s paths=%s glob=%s context=%s offset=%s \
           limit=%s"
          (Search_text.Input.pattern input)
          (input_mode (Search_text.Input.mode input))
          (input_case (Search_text.Input.case input))
          (match Search_text.Input.paths input with
          | None -> "-"
          | Some paths -> String.concat "," paths)
          (Option.value (Search_text.Input.glob input) ~default:"-")
          (option_int (Search_text.Input.context_lines input))
          (option_int (Search_text.Input.offset input))
          (option_int (Search_text.Input.limit input))
    | exception Invalid_argument message -> "exception " ^ message
  in
  Printf.printf "%s: %s\n" label result

let print_invalid_constructor label f =
  match f () with
  | _ -> Printf.printf "%s: accepted\n" label
  | exception Invalid_argument message ->
      Printf.printf "%s: invalid %s\n" label message

let with_ripgrep_config contents f =
  let config = Filename.temp_file "spice-search-text-rg-" ".conf" in
  let previous = Sys.getenv_opt "RIPGREP_CONFIG_PATH" in
  Fun.protect
    ~finally:(fun () ->
      rm_rf config;
      match previous with
      | Some value -> Unix.putenv "RIPGREP_CONFIG_PATH" value
      | None -> Unix.putenv "RIPGREP_CONFIG_PATH" "")
    (fun () ->
      write_disk config contents;
      Unix.putenv "RIPGREP_CONFIG_PATH" config;
      f ())

let with_path value f =
  let previous = Sys.getenv_opt "PATH" in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv "PATH" value
      | None -> Unix.putenv "PATH" "")
    (fun () ->
      Unix.putenv "PATH" value;
      f ())

let json_member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | _ -> None

let%expect_test "input contract" =
  print_decode "minimal" (json_obj [ ("pattern", Json.string "alpha") ]);
  print_decode "full"
    (json_obj
       [
         ("pattern", Json.string "Alpha");
         ("paths", Json.list [ Json.string "src"; Json.string "lib" ]);
         ("glob", Json.string "*.ml");
         ("mode", Json.string "matches");
         ("case_insensitive", Json.bool true);
         ("context_lines", Json.int 2);
         ("offset", Json.int 3);
         ("limit", Json.int 4);
       ]);
  print_decode "unknown field"
    (json_obj
       [ ("pattern", Json.string "alpha"); ("recursive", Json.bool true) ]);
  print_decode "bad mode"
    (json_obj
       [ ("pattern", Json.string "alpha"); ("mode", Json.string "lines") ]);
  print_decode "bad context"
    (json_obj
       [
         ("pattern", Json.string "alpha");
         ("mode", Json.string "files");
         ("context_lines", Json.int 1);
       ]);
  print_decode "bad regex" (json_obj [ ("pattern", Json.string "[") ]);
  print_invalid_constructor "empty pattern" (fun () ->
      Search_text.Input.make "");
  print_invalid_constructor "empty paths" (fun () ->
      Search_text.Input.make ~paths:[] "alpha");
  print_invalid_constructor "limit zero" (fun () ->
      Search_text.Input.make ~limit:0 "alpha");
  [%expect
    {|
    minimal: ok pattern=alpha mode=files case=sensitive paths=- glob=- context=- offset=- limit=-
    full: ok pattern=Alpha mode=matches case=insensitive paths=src,lib glob=*.ml context=2 offset=3 limit=4
    unknown field: error
    bad mode: error
    bad context: error
    bad regex: ok pattern=[ mode=files case=sensitive paths=- glob=- context=- offset=- limit=-
    empty pattern: invalid pattern must not be empty
    empty paths: invalid paths must not be empty
    limit zero: invalid limit must be positive |}]

let%expect_test "files count and matches modes" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "files";
  run ~fs ~workspace (Search_text.Input.make "alpha");
  print_case "count";
  run ~fs ~workspace
    (Search_text.Input.make ~mode:Search_text.Input.Count "alpha");
  print_case "matches with context";
  run ~fs ~workspace
    (Search_text.Input.make ~paths:[ "src/app.ml" ]
       ~mode:Search_text.Input.Matches ~context_lines:1 "alpha");
  [%expect
    {|
    -- files --
    query: pattern="alpha" roots=. glob=- mode=files case=sensitive context=0
    page: returned=3 total=exact 3 offset=1 limit=100 status=complete has_more=false next=none
    skipped: bad-utf8.txt:invalid_utf8
    files: .env lib/util.ml src/app.ml
    -- count --
    query: pattern="alpha" roots=. glob=- mode=count case=sensitive context=0
    page: returned=3 total=exact 3 offset=1 limit=100 status=complete has_more=false next=none
    skipped: bad-utf8.txt:invalid_utf8
    counts: .env:1 lib/util.ml:2 src/app.ml:2
    matching_lines: exact 5
    -- matches with context --
    query: pattern="alpha" roots=src/app.ml glob=- mode=matches case=sensitive context=1
    page: returned=2 total=exact 2 offset=1 limit=100 status=complete has_more=false next=none
    spans: src/app.ml [1:match:let alpha = 1; 2:match:let beta = alpha + 1; 3:context:let gamma = beta] |}]

let%expect_test "plural paths glob dotfiles and protected metadata" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "plural paths";
  run ~fs ~workspace
    (Search_text.Input.make ~paths:[ "lib"; "src/app.ml" ] "alpha");
  print_case "glob ml";
  run ~fs ~workspace (Search_text.Input.make ~glob:"*.ml" "alpha");
  print_case "glob dotfile";
  run ~fs ~workspace (Search_text.Input.make ~glob:".*" "alpha");
  print_case "protected vcs";
  run ~fs ~workspace (Search_text.Input.make "secret");
  [%expect
    {|
    -- plural paths --
    query: pattern="alpha" roots=lib src/app.ml glob=- mode=files case=sensitive context=0
    page: returned=2 total=exact 2 offset=1 limit=100 status=complete has_more=false next=none
    files: lib/util.ml src/app.ml
    -- glob ml --
    query: pattern="alpha" roots=. glob=*.ml mode=files case=sensitive context=0
    page: returned=2 total=exact 2 offset=1 limit=100 status=complete has_more=false next=none
    files: lib/util.ml src/app.ml
    -- glob dotfile --
    query: pattern="alpha" roots=. glob=.* mode=files case=sensitive context=0
    page: returned=1 total=exact 1 offset=1 limit=100 status=complete has_more=false next=none
    files: .env
    -- protected vcs --
    query: pattern="secret" roots=. glob=- mode=files case=sensitive context=0
    page: returned=0 total=exact 0 offset=1 limit=100 status=complete has_more=false next=none
    files: - |}]

let%expect_test "pagination and structured continuation" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "first page";
  let result =
    Search_text.run ~sandbox ~fs ~workspace
      (Search_text.Input.make ~limit:2 "alpha")
  in
  print_result result;
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "search_text returned no output"
  in
  let next_json =
    match Tool.Output.json (Search_text.Output.encode output) with
    | Some json -> (
        match json_member "next" json with
        | Some next -> next
        | None -> failf "output JSON has no next field")
    | None -> failf "output has no JSON"
  in
  print_case "next json";
  begin match Search_text.Input.decode next_json with
  | Ok input -> Printf.printf "next: %s\n" (next (Some input))
  | Error error -> Printf.printf "decode error: %s\n" error
  end;
  print_case "final page";
  run ~fs ~workspace (Search_text.Input.make ~offset:3 ~limit:2 "alpha");
  [%expect
    {|
    -- first page --
    query: pattern="alpha" roots=. glob=- mode=files case=sensitive context=0
    page: returned=2 total=exact 3 offset=1 limit=2 status=partial limit has_more=true next=mode=files paths=. offset=3 limit=2
    skipped: bad-utf8.txt:invalid_utf8
    files: .env lib/util.ml
    -- next json --
    next: mode=files paths=. offset=3 limit=2
    -- final page --
    query: pattern="alpha" roots=. glob=- mode=files case=sensitive context=0
    page: returned=1 total=exact 3 offset=3 limit=2 status=complete has_more=false next=none
    skipped: bad-utf8.txt:invalid_utf8
    files: src/app.ml |}]

let%expect_test "continuation text escapes special input characters" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  let result =
    Search_text.run ~sandbox ~fs ~workspace
      (Search_text.Input.make ~paths:[ "odd\n\".txt" ]
         ~mode:Search_text.Input.Matches ~limit:1 "needle|\"")
  in
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "search_text returned no output"
  in
  let rendered = Tool.Output.text (Search_text.Output.encode output) in
  String.split_on_char '\n' rendered
  |> List.find_opt (String.starts_with ~prefix:"next:")
  |> Option.value ~default:"<missing next>"
  |> String.escaped |> Printf.printf "%s\n";
  [%expect
    {| next: search_text {\"pattern\":\"needle|\\\"\",\"paths\":[\"odd\\n\\\".txt\"],\"mode\":\"matches\",\"case_insensitive\":false,\"context_lines\":0,\"offset\":2,\"limit\":1} |}]

let%expect_test "case sensitivity" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "sensitive";
  run ~fs ~workspace
    (Search_text.Input.make ~paths:[ "docs/readme.md"; "src/app.ml" ] "Alpha");
  print_case "insensitive";
  run ~fs ~workspace
    (Search_text.Input.make
       ~paths:[ "docs/readme.md"; "src/app.ml" ]
       ~case:Search_text.Input.Insensitive "Alpha");
  [%expect
    {|
    -- sensitive --
    query: pattern="Alpha" roots=docs/readme.md src/app.ml glob=- mode=files case=sensitive context=0
    page: returned=1 total=exact 1 offset=1 limit=100 status=complete has_more=false next=none
    files: docs/readme.md
    -- insensitive --
    query: pattern="Alpha" roots=docs/readme.md src/app.ml glob=- mode=files case=insensitive context=0
    page: returned=2 total=exact 2 offset=1 limit=100 status=complete has_more=false next=none
    files: docs/readme.md src/app.ml |}]

let%expect_test "ripgrep diagnostics config and ignores" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "bad regex";
  run ~fs ~workspace (Search_text.Input.make "[");
  print_case "bad glob";
  run ~fs ~workspace (Search_text.Input.make ~glob:"[" "alpha");
  print_case "ignore file";
  run ~fs ~workspace (Search_text.Input.make ~paths:[ "." ] "alpha ignored");
  print_case "config disabled";
  with_ripgrep_config "--ignore-case\n" @@ fun () ->
  run ~fs ~workspace
    (Search_text.Input.make ~paths:[ "docs/readme.md"; "src/app.ml" ] "Alpha");
  [%expect
    {|
    -- bad regex --
    failed invalid_input: rg: regex parse error:
        (?:[)
           ^
    error: unclosed character class
    -- bad glob --
    failed invalid_input: rg: error parsing glob '[': unclosed character class; missing ']'
    -- ignore file --
    query: pattern="alpha ignored" roots=. glob=- mode=files case=sensitive context=0
    page: returned=0 total=exact 0 offset=1 limit=100 status=complete has_more=false next=none
    files: -
    -- config disabled --
    query: pattern="Alpha" roots=docs/readme.md src/app.ml glob=- mode=files case=sensitive context=0
    page: returned=1 total=exact 1 offset=1 limit=100 status=complete has_more=false next=none
    files: docs/readme.md |}]

let%expect_test "missing ripgrep is a crisp tool failure" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  with_path "" @@ fun () ->
  run ~fs ~workspace (Search_text.Input.make "alpha");
  [%expect
    {|
    failed failed: ripgrep executable not found; search_text requires rg in PATH |}]

let%expect_test "binary and invalid UTF-8 files are skipped" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  run ~fs ~workspace
    (Search_text.Input.make
       ~paths:[ "bad.bin"; "bad-utf8.txt"; "src/app.ml" ]
       "alpha");
  [%expect
    {|
    query: pattern="alpha" roots=bad.bin bad-utf8.txt src/app.ml glob=- mode=files case=sensitive context=0
    page: returned=1 total=exact 1 offset=1 limit=100 status=complete has_more=false next=none
    skipped: bad-utf8.txt:invalid_utf8 bad.bin:binary
    files: src/app.ml |}]

let%expect_test "unsafe roots fail" =
  with_fixture @@ fun ~outside ~fs ~workspace ->
  let cases =
    [
      ("missing", Search_text.Input.make ~paths:[ "missing" ] "alpha", None);
      ( "symlink root",
        Search_text.Input.make ~paths:[ "src_link" ] "alpha",
        None );
      ( "outside workspace",
        Search_text.Input.make ~paths:[ outside ] "alpha",
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
    -- missing --
    failed not_found: missing: path does not exist
    -- symlink root --
    failed invalid_input: src_link: symlink search roots are not supported
    -- outside workspace --
    failed invalid_input: path is outside workspace: <outside> |}]

let%expect_test "erased tool adapter permissions rendering and cancellation" =
  with_fixture @@ fun ~outside:_ ~fs ~workspace ->
  print_case "adapter";
  let tool =
    Search_text.tool ~sandbox ~fs ~workspace
      ~render:(Search_text.Output.anchored ()) ()
  in
  let call =
    match
      Tool.Call.decode [ tool ] ~name:Search_text.name
        ~input:
          (json_obj
             [
               ("pattern", Json.string "alpha");
               ("paths", Json.list [ Json.string "src/app.ml" ]);
               ("mode", Json.string "matches");
               ("context_lines", Json.int 0);
               ("limit", Json.int 1);
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
  | Some output ->
      let lines = String.split_on_char '\n' (Tool.Output.text output) in
      List.iter print_endline (take 4 lines);
      Printf.printf "truncated=%b\n" (Tool.Output.truncated output)
  | None -> failf "adapter returned no output"
  end;
  print_case "cancelled";
  let calls = ref 0 in
  let cancelled () =
    incr calls;
    !calls > 1
  in
  Search_text.run ~sandbox ~fs ~workspace ~cancelled
    (Search_text.Input.make ~paths:[ "src/app.ml" ] "alpha")
  |> print_result;
  [%expect
    {|
    -- adapter --
    permissions: 1
    pattern="alpha" mode=matches results=1/2 offset=1 limit=1 status=partial
    src/app.ml
      1 #43a8220f0727: let alpha = 1
    next: search_text {"pattern":"alpha","paths":["src/app.ml"],"mode":"matches","case_insensitive":false,"context_lines":0,"offset":2,"limit":1}
    truncated=false
    -- cancelled --
    interrupted cancelled=true: tool call cancelled |}]

[%%run_tests "spice.tools.search_text.expect"]
