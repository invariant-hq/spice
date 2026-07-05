(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Json = Jsont.Json
module Read_file = Spice_tools.Read_file
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

let identity_exn value =
  match Spice_digest.Identity.of_string value with
  | Ok identity -> identity
  | Error error ->
      failf "invalid identity %S: %s" value
        (Spice_digest.Identity.Parse_error.message error)

let test_identity_string =
  Spice_digest.Identity.to_string (Spice_digest.Identity.of_contents "seen")

let range ?offset ?limit () =
  match (offset, limit) with
  | None, None -> None
  | Some start_line, max_lines ->
      Some (Read_file.Range.lines ?max_lines ~start_line ())
  | None, Some max_lines ->
      Some (Read_file.Range.lines ~start_line:1 ~max_lines ())

let input ?offset ?limit ?max_bytes ?if_identity path =
  let range = range ?offset ?limit () in
  let if_identity = Option.map identity_exn if_identity in
  Read_file.Input.make ?range ?max_bytes ?if_identity path

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

let with_temp_dir f =
  let dir = Filename.temp_file "spice-read-file-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let mkdir_p dir =
  let rec loop dir =
    if Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  loop dir

let write_file file contents =
  mkdir_p (Filename.dirname file);
  let oc = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc contents;
      flush oc)

let with_fixture f =
  with_temp_dir @@ fun root ->
  let outside = Filename.temp_file "spice-read-file-outside-" ".txt" in
  let outside_dir = Filename.temp_file "spice-read-file-outside-dir-" ".tmp" in
  Unix.unlink outside_dir;
  Unix.mkdir outside_dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      rm_rf outside;
      rm_rf outside_dir)
    (fun () ->
      write_file (path root "note.txt") "alpha\nbravo\ncharlie\ndelta\n";
      write_file (path root "odd\n\".txt") "one\ntwo\nthree\n";
      write_file (path root "utf8.txt") "\195\169x\n";
      write_file (path root "long.txt") (String.make 2_005 'x' ^ "\n");
      write_file
        (path root "displayed-long.txt")
        (String.make 2_000 'x' ^ " [line truncated]\n");
      write_file (path root "bad.bin") "\255\000";
      write_file (path root "bad-utf8.txt") "\255\254\n";
      write_file outside "secret\n";
      Unix.mkdir (path root "dir") 0o755;
      Unix.mkfifo (path root "fifo") 0o644;
      Unix.symlink "note.txt" (path root "link_note.txt");
      Unix.symlink outside (path root "link_outside.txt");
      (* Directory-listing fixture, mirroring the retired list_directory tool. *)
      let subject = path root "subject" in
      Unix.mkdir subject 0o755;
      Unix.mkdir (path subject ".config") 0o755;
      Unix.mkdir (path subject "alpha_dir") 0o755;
      Unix.mkdir (path subject "beta_dir") 0o755;
      Unix.mkdir (path subject ".git") 0o755;
      Unix.mkdir (path subject ".git/hooks") 0o755;
      write_file (path subject ".git/config") "repo metadata\n";
      write_file (path subject ".env") "A=1\n";
      write_file (path subject "alpha.txt") "alpha\n";
      write_file (path subject "beta.txt") "beta\n";
      Unix.mkfifo (path subject "pipe") 0o644;
      Unix.symlink "alpha_dir" (path subject "dir_link");
      Unix.symlink "alpha.txt" (path subject "file_link");
      Unix.mkdir (path root "empty_dir") 0o755;
      Unix.symlink "subject" (path root "subject_link");
      Unix.symlink outside_dir (path root "link_outside_dir");
      let big = path root "big_dir" in
      Unix.mkdir big 0o755;
      for i = 1 to 205 do
        write_file (path big (Printf.sprintf "f%03d.txt" i)) "x\n"
      done;
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env -> f ~fs:(Eio.Stdenv.fs env) ~workspace)

let total_lines = function
  | Read_file.Output.Exact n -> Printf.sprintf "exact %d" n
  | Read_file.Output.Lower_bound n -> Printf.sprintf "lower_bound %d" n
  | Read_file.Output.Unknown -> "unknown"

let partial_reason = function
  | Read_file.Output.Ranged -> "ranged"
  | Read_file.Output.Byte_capped -> "byte_capped"
  | Read_file.Output.Ranged_and_byte_capped -> "ranged_and_byte_capped"

let identity = function
  | None -> "-"
  | Some value -> Spice_digest.Identity.to_string value

let next = function
  | None -> "none"
  | Some request -> (
      match Read_file.Input.range request with
      | Read_file.Range.All -> "all"
      | Read_file.Range.Lines { start_line; max_lines } ->
          Printf.sprintf "offset:%d limit:%s" start_line
            (match max_lines with None -> "-" | Some n -> string_of_int n))

let status = function
  | Read_file.Output.Complete identity ->
      "complete identity=" ^ Spice_digest.Identity.to_string identity
  | Read_file.Output.Partial
      { Read_file.Output.reason; Read_file.Output.next = next_request } ->
      Printf.sprintf "partial reason=%s next=%s" (partial_reason reason)
        (next next_request)

let fingerprint = function
  | None -> "-"
  | Some fingerprint ->
      Printf.sprintf "size=%Ld mtime_ns=%b"
        (Read_file.Fingerprint.size fingerprint)
        (Option.is_some (Read_file.Fingerprint.mtime_ns_approx fingerprint))

let entry_kind = function
  | Read_file.Entry.Regular_file -> "file"
  | Read_file.Entry.Directory -> "dir"
  | Read_file.Entry.Symlink -> "symlink"
  | Read_file.Entry.Other -> "other"

let entries_text = function
  | [] -> "-"
  | entries ->
      String.concat " "
        (List.map
           (fun (entry : Read_file.Entry.t) ->
             Printf.sprintf "%s:%s"
               (entry_kind entry.Read_file.Entry.kind)
               entry.Read_file.Entry.name)
           entries)

let print_output output =
  match output with
  | Read_file.Output.Listing listing ->
      Printf.printf "path: %s\n"
        (Workspace.Path.display listing.Read_file.Output.listing_path);
      Printf.printf "entries: %s\n"
        (entries_text listing.Read_file.Output.entries);
      Printf.printf
        "listing: returned=%d total=%d offset=%d limit=%d complete=%b next=%s\n"
        (List.length listing.Read_file.Output.entries)
        listing.Read_file.Output.total_entries
        listing.Read_file.Output.listing_offset
        listing.Read_file.Output.listing_limit
        listing.Read_file.Output.listing_complete
        (next listing.Read_file.Output.listing_next)
  | Read_file.Output.Read read ->
      Printf.printf "path: %s\n"
        (Workspace.Path.display read.Read_file.Output.read_path);
      Printf.printf "contents: %S\n" read.Read_file.Output.contents;
      Printf.printf
        "evidence: start=%d returned=%d total=%s status=%s fingerprint=%s\n"
        read.Read_file.Output.start_line read.Read_file.Output.returned_lines
        (total_lines read.Read_file.Output.total_lines)
        (status read.Read_file.Output.status)
        (fingerprint read.Read_file.Output.read_fingerprint)
  | Read_file.Output.Unchanged unchanged ->
      Printf.printf "path: %s\n"
        (Workspace.Path.display unchanged.Read_file.Output.unchanged_path);
      Printf.printf "contents: <unchanged>\n";
      Printf.printf "evidence: status=unchanged identity=%s fingerprint=%s\n"
        (Spice_digest.Identity.to_string unchanged.Read_file.Output.identity)
        (fingerprint unchanged.Read_file.Output.unchanged_fingerprint)

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

let run ~fs ~workspace input =
  Read_file.run ~fs ~workspace input |> print_result

let print_render_summary output =
  let text = Tool.Output.text output in
  match String.split_on_char '\n' text with
  | header :: body :: _ ->
      Printf.printf "header: %s\n" header;
      Printf.printf "body length: %d\n" (String.length body);
      Printf.printf "body truncated: %b\n"
        (String.ends_with ~suffix:" [line truncated]" body)
  | _ -> failf "unexpected rendered output: %S" text

let output_roundtrip output =
  match Json.encode Tool.Output.jsont output with
  | Error message -> failf "could not encode tool output: %s" message
  | Ok json -> (
      match Json.decode Tool.Output.jsont json with
      | Ok output -> output
      | Error message -> failf "could not decode tool output: %s" message)

let print_recovered_output output =
  match Read_file.Output.of_tool_output output with
  | None -> print_endline "not recovered"
  | Some (Read_file.Output.Read read) ->
      Printf.printf
        "recovered read path=%s start=%d returned=%d total=%s status=%s \
         contents=%S\n"
        (Workspace.Path.display read.Read_file.Output.read_path)
        read.Read_file.Output.start_line read.Read_file.Output.returned_lines
        (total_lines read.Read_file.Output.total_lines)
        (match read.Read_file.Output.status with
        | Read_file.Output.Complete _ -> "complete"
        | Read_file.Output.Partial
            { Read_file.Output.reason; Read_file.Output.next = _ } ->
            "partial " ^ partial_reason reason)
        read.Read_file.Output.contents
  | Some (Read_file.Output.Unchanged unchanged) ->
      Printf.printf "recovered unchanged path=%s\n"
        (Workspace.Path.display unchanged.Read_file.Output.unchanged_path)
  | Some (Read_file.Output.Listing listing) ->
      Printf.printf
        "recovered listing path=%s returned=%d total=%d complete=%b next=%s \
         entries=%s\n"
        (Workspace.Path.display listing.Read_file.Output.listing_path)
        (List.length listing.Read_file.Output.entries)
        listing.Read_file.Output.total_entries
        listing.Read_file.Output.listing_complete
        (next listing.Read_file.Output.listing_next)
        (entries_text listing.Read_file.Output.entries)

let print_decode label conditional_read json =
  let status =
    match Read_file.Input.decode ~conditional_read json with
    | Ok input ->
        Printf.sprintf "ok path=%s if_identity=%s"
          (Read_file.Input.path input)
          (identity (Read_file.Input.if_identity input))
    | Error _ -> "error"
  in
  Printf.printf "%s: %s\n" label status

let print_invalid_constructor label f =
  match f () with
  | _ -> Printf.printf "%s: accepted\n" label
  | exception Invalid_argument message ->
      Printf.printf "%s: invalid %s\n" label message

let json_member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | _ -> None

let%expect_test "input contract" =
  let conditional =
    json_obj
      [
        ("path", Json.string "note.txt");
        ("if_identity", Json.string test_identity_string);
      ]
  in
  let ranged_conditional =
    json_obj
      [
        ("path", Json.string "note.txt");
        ("offset", Json.int 2);
        ("if_identity", Json.string test_identity_string);
      ]
  in
  print_decode "default rejects if_identity" false conditional;
  print_decode "conditional accepts if_identity" true conditional;
  print_decode "conditional rejects ranged if_identity" true ranged_conditional;
  print_invalid_constructor "limit zero" (fun () -> input ~limit:0 "note.txt");
  [%expect
    {|
    default rejects if_identity: error
    conditional accepts if_identity: ok path=note.txt if_identity=sha256:7208794c984ea1c75d13877c7427336fe98722c41a056eeee4f37360ec367123:4
    conditional rejects ranged if_identity: error
    limit zero: invalid max_lines must be positive |}]

let%expect_test "typed reads" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "complete";
  let complete = Read_file.run ~fs ~workspace (input "note.txt") in
  print_result complete;
  let complete_identity =
    match Tool.Result.output complete with
    | Some (Read_file.Output.Read read) -> (
        match read.Read_file.Output.status with
        | Read_file.Output.Complete identity ->
            Spice_digest.Identity.to_string identity
        | Read_file.Output.Partial _ ->
            failf "complete read did not return complete status")
    | Some (Read_file.Output.Unchanged _) ->
        failf "complete read returned unchanged status"
    | Some (Read_file.Output.Listing _) ->
        failf "complete read returned a directory listing"
    | None -> failf "complete read did not return identity"
  in
  print_case "unchanged";
  run ~fs ~workspace (input ~if_identity:complete_identity "note.txt");
  print_case "range";
  run ~fs ~workspace (input ~offset:2 ~limit:2 "note.txt");
  print_case "range covering whole file";
  run ~fs ~workspace (input ~offset:1 ~limit:99 "note.txt");
  print_case "range covering exactly all lines";
  run ~fs ~workspace (input ~offset:1 ~limit:4 "note.txt");
  print_case "past eof";
  run ~fs ~workspace (input ~offset:99 "note.txt");
  print_case "utf8 byte cap";
  run ~fs ~workspace (input ~max_bytes:2 "utf8.txt");
  [%expect
    {|
    -- complete --
    path: note.txt
    contents: "alpha\nbravo\ncharlie\ndelta\n"
    evidence: start=1 returned=4 total=exact 4 status=complete identity=sha256:833940e53452e86ad3cf12deb4054606301b43cec7607677dab4625777c7cee3:26 fingerprint=size=26 mtime_ns=true
    -- unchanged --
    path: note.txt
    contents: <unchanged>
    evidence: status=unchanged identity=sha256:833940e53452e86ad3cf12deb4054606301b43cec7607677dab4625777c7cee3:26 fingerprint=size=26 mtime_ns=true
    -- range --
    path: note.txt
    contents: "bravo\ncharlie\n"
    evidence: start=2 returned=2 total=lower_bound 3 status=partial reason=ranged next=offset:4 limit:2 fingerprint=size=26 mtime_ns=true
    -- range covering whole file --
    path: note.txt
    contents: "alpha\nbravo\ncharlie\ndelta\n"
    evidence: start=1 returned=4 total=exact 4 status=complete identity=sha256:833940e53452e86ad3cf12deb4054606301b43cec7607677dab4625777c7cee3:26 fingerprint=size=26 mtime_ns=true
    -- range covering exactly all lines --
    path: note.txt
    contents: "alpha\nbravo\ncharlie\ndelta\n"
    evidence: start=1 returned=4 total=exact 4 status=complete identity=sha256:833940e53452e86ad3cf12deb4054606301b43cec7607677dab4625777c7cee3:26 fingerprint=size=26 mtime_ns=true
    -- past eof --
    path: note.txt
    contents: ""
    evidence: start=99 returned=0 total=exact 4 status=partial reason=ranged next=none fingerprint=size=26 mtime_ns=true
    -- utf8 byte cap --
    path: utf8.txt
    contents: "\195\169"
    evidence: start=1 returned=1 total=lower_bound 1 status=partial reason=byte_capped next=none fingerprint=size=4 mtime_ns=true |}]

let%expect_test "durable output recovers typed read evidence" =
  with_fixture @@ fun ~fs ~workspace ->
  let result = Read_file.run ~fs ~workspace (input "note.txt") in
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "read_file completed without output"
  in
  print_recovered_output (output_roundtrip (Read_file.Output.encode output));
  [%expect
    {|
    recovered read path=note.txt start=1 returned=4 total=exact 4 status=complete contents="alpha\nbravo\ncharlie\ndelta\n" |}]

let%expect_test "safety" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "symlink inside workspace";
  run ~fs ~workspace (input "link_note.txt");
  print_case "symlink escapes workspace";
  run ~fs ~workspace (input "link_outside.txt");
  print_case "fifo";
  run ~fs ~workspace (input "fifo");
  [%expect
    {|
    -- symlink inside workspace --
    path: link_note.txt
    contents: "alpha\nbravo\ncharlie\ndelta\n"
    evidence: start=1 returned=4 total=exact 4 status=complete identity=sha256:833940e53452e86ad3cf12deb4054606301b43cec7607677dab4625777c7cee3:26 fingerprint=size=26 mtime_ns=true
    -- symlink escapes workspace --
    failed invalid_input: link_outside.txt: path resolves outside workspace
    -- fifo --
    failed invalid_input: fifo: not a readable file or directory |}]

let%expect_test "erased adapter" =
  with_fixture @@ fun ~fs ~workspace ->
  let tool = Read_file.tool ~fs ~workspace ~conditional_read:true () in
  let input =
    json_obj
      [
        ("path", Json.string "note.txt");
        ("offset", Json.int 2);
        ("limit", Json.int 2);
      ]
  in
  let call =
    match Tool.Call.decode [ tool ] ~name:Read_file.name ~input () with
    | Ok call -> call
    | Error error -> failf "decode failed: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  begin match Tool.Result.output result with
  | Some output ->
      print_string (Tool.Output.text output);
      Printf.printf "truncated: %b\n" (Tool.Output.truncated output)
  | None -> failf "adapter returned no output"
  end;
  [%expect
    {|
    permissions: 1
    note.txt lines=2-3 returned=2/>=3 status=partial reason=ranged
    2	bravo
    3	charlie
    next: read_file {"path":"note.txt","offset":4,"limit":2}
    truncated: false |}]

let%expect_test "structured continuation is valid input" =
  with_fixture @@ fun ~fs ~workspace ->
  let result =
    Read_file.run ~fs ~workspace (input ~offset:2 ~limit:2 "note.txt")
  in
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "read returned no output"
  in
  let next_json =
    match Tool.Output.json (Read_file.Output.encode output) with
    | Some json -> (
        match json_member "status" json with
        | Some status -> (
            match json_member "next" status with
            | Some next -> next
            | None -> failf "status has no next")
        | None -> failf "output has no status")
    | None -> failf "output has no JSON"
  in
  begin match Read_file.Input.decode ~conditional_read:false next_json with
  | Ok input ->
      Printf.printf "next: path=%s %s\n"
        (Read_file.Input.path input)
        (next (Some input))
  | Error error -> Printf.printf "decode error: %s\n" error
  end;
  [%expect {| next: path=note.txt offset:4 limit:2 |}]

let%expect_test "continuation text escapes special path characters" =
  with_fixture @@ fun ~fs ~workspace ->
  let result =
    Read_file.run ~fs ~workspace (input ~offset:1 ~limit:1 "odd\n\".txt")
  in
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "read returned no output"
  in
  let rendered = Tool.Output.text (Read_file.Output.encode output) in
  String.split_on_char '\n' rendered
  |> List.find_opt (String.starts_with ~prefix:"next:")
  |> Option.value ~default:"<missing next>"
  |> String.escaped |> Printf.printf "%s\n";
  [%expect
    {| next: read_file {\"path\":\"odd\\n\\\".txt\",\"offset\":2,\"limit\":1} |}]

let%expect_test "anchored adapter" =
  with_fixture @@ fun ~fs ~workspace ->
  let tool =
    Read_file.tool ~fs ~workspace ~conditional_read:true
      ~render:(Read_file.Output.anchored ())
      ()
  in
  let input =
    json_obj
      [
        ("path", Json.string "note.txt");
        ("offset", Json.int 2);
        ("limit", Json.int 2);
      ]
  in
  let call =
    match Tool.Call.decode [ tool ] ~name:Read_file.name ~input () with
    | Ok call -> call
    | Error error -> failf "decode failed: %a" Tool.Error.pp error
  in
  begin match Tool.Result.output (Tool.Call.run call ()) with
  | Some output -> print_string (Tool.Output.text output)
  | None -> failf "adapter returned no output"
  end;
  [%expect
    {|
    note.txt lines=2-3 returned=2/>=3 status=partial reason=ranged anchors=enabled
    2 72fa760ebcdb	bravo
    3 0d47a26163be	charlie
    next: read_file {"path":"note.txt","offset":4,"limit":2} |}]

let%expect_test "display rendering" =
  with_fixture @@ fun ~fs ~workspace ->
  let result = Read_file.run ~fs ~workspace (input "long.txt") in
  begin match Tool.Result.output result with
  | Some output -> print_render_summary (Read_file.Output.encode output)
  | None -> failf "read returned no output"
  end;
  [%expect
    {|
    header: long.txt lines=1-1 returned=1/1 status=complete identity=sha256:a3df5a61da0b9614bd88f733d2897a461835dc98916515fb0a10d14fd281b8ac:2006
    body length: 2019
    body truncated: true |}]

let rendered_anchor output =
  let text =
    Tool.Output.text
      (Read_file.Output.encode ~render:(Read_file.Output.anchored ()) output)
  in
  match String.split_on_char '\n' text with
  | _header :: line :: _ -> (
      match String.split_on_char '\t' line with
      | prefix :: _ -> (
          match String.split_on_char ' ' prefix with
          | [ _number; anchor ] -> anchor
          | _ -> failf "unexpected anchored prefix: %S" prefix)
      | _ -> failf "unexpected anchored line: %S" line)
  | _ -> failf "unexpected anchored output: %S" text

let%expect_test "long-line anchors use raw line text" =
  with_fixture @@ fun ~fs ~workspace ->
  let result = Read_file.run ~fs ~workspace (input "long.txt") in
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "read returned no output"
  in
  let actual = rendered_anchor output in
  let displayed_result =
    Read_file.run ~fs ~workspace (input "displayed-long.txt")
  in
  let displayed_output =
    match Tool.Result.output displayed_result with
    | Some output -> output
    | None -> failf "displayed read returned no output"
  in
  let displayed_anchor = rendered_anchor displayed_output in
  Printf.printf "matches displayed-text anchor: %b\n"
    (String.equal actual displayed_anchor);
  Printf.printf "read anchor: %s\n" actual;
  [%expect
    {|
    matches displayed-text anchor: false
    read anchor: 90d1218c442b |}]

let%expect_test "failures" =
  with_fixture @@ fun ~fs ~workspace ->
  run ~fs ~workspace (input "missing.txt");
  run ~fs ~workspace (input "nate.txt");
  run ~fs ~workspace (input "bad.bin");
  run ~fs ~workspace (input "bad-utf8.txt");
  run ~fs ~workspace (input "/outside-spice-read-file-test");
  [%expect
    {|
    failed not_found: missing.txt: path does not exist
    failed not_found: nate.txt: path does not exist. Did you mean: note.txt?
    failed invalid_input: bad.bin: binary file
    failed invalid_input: bad-utf8.txt: not valid UTF-8 text
    failed invalid_input: path is outside workspace: /outside-spice-read-file-test |}]

let%expect_test "cancellation" =
  with_fixture @@ fun ~fs ~workspace ->
  let polls = ref 0 in
  let cancelled () =
    incr polls;
    !polls > 1
  in
  Read_file.run ~fs ~workspace ~cancelled (input "note.txt") |> print_result;
  [%expect {| interrupted cancelled=true: tool call cancelled |}]

let%expect_test "directory listing" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "sorted entries with dotfiles and VCS filtering";
  run ~fs ~workspace (input "subject");
  print_case "explicitly named .git is listed";
  run ~fs ~workspace (input "subject/.git");
  print_case "empty directory";
  run ~fs ~workspace (input "empty_dir");
  [%expect
    {|
    -- sorted entries with dotfiles and VCS filtering --
    path: subject
    entries: dir:.config dir:alpha_dir dir:beta_dir file:.env file:alpha.txt file:beta.txt symlink:dir_link symlink:file_link other:pipe
    listing: returned=9 total=9 offset=1 limit=200 complete=true next=none
    -- explicitly named .git is listed --
    path: subject/.git
    entries: dir:hooks file:config
    listing: returned=2 total=2 offset=1 limit=200 complete=true next=none
    -- empty directory --
    path: empty_dir
    entries: -
    listing: returned=0 total=0 offset=1 limit=200 complete=true next=none |}]

let%expect_test "directory paging" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "first page";
  run ~fs ~workspace (input ~limit:4 "subject");
  print_case "final page";
  run ~fs ~workspace (input ~offset:7 ~limit:4 "subject");
  print_case "past end";
  run ~fs ~workspace (input ~offset:99 ~limit:4 "subject");
  [%expect
    {|
    -- first page --
    path: subject
    entries: dir:.config dir:alpha_dir dir:beta_dir file:.env
    listing: returned=4 total=9 offset=1 limit=4 complete=false next=offset:5 limit:4
    -- final page --
    path: subject
    entries: symlink:dir_link symlink:file_link other:pipe
    listing: returned=3 total=9 offset=7 limit=4 complete=true next=none
    -- past end --
    path: subject
    entries: -
    listing: returned=0 total=9 offset=99 limit=4 complete=true next=none |}]

let%expect_test "directory default entry budget" =
  with_fixture @@ fun ~fs ~workspace ->
  (match
     Tool.Result.output (Read_file.run ~fs ~workspace (input "big_dir"))
   with
  | Some (Read_file.Output.Listing listing) ->
      Printf.printf
        "returned=%d total=%d complete=%b next=%s first=%s last=%s\n"
        (List.length listing.Read_file.Output.entries)
        listing.Read_file.Output.total_entries
        listing.Read_file.Output.listing_complete
        (next listing.Read_file.Output.listing_next)
        (match listing.Read_file.Output.entries with
        | (entry : Read_file.Entry.t) :: _ -> entry.Read_file.Entry.name
        | [] -> "-")
        (match List.rev listing.Read_file.Output.entries with
        | (entry : Read_file.Entry.t) :: _ -> entry.Read_file.Entry.name
        | [] -> "-")
  | _ -> failf "expected a directory listing");
  [%expect
    {| returned=200 total=205 complete=false next=offset:201 limit:200 first=f001.txt last=f200.txt |}]

let%expect_test "directory symlink roots" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "symlink to in-workspace directory is followed";
  run ~fs ~workspace (input "subject_link");
  print_case "symlink to out-of-workspace directory is rejected";
  run ~fs ~workspace (input "link_outside_dir");
  [%expect
    {|
    -- symlink to in-workspace directory is followed --
    path: subject_link
    entries: dir:.config dir:alpha_dir dir:beta_dir file:.env file:alpha.txt file:beta.txt symlink:dir_link symlink:file_link other:pipe
    listing: returned=9 total=9 offset=1 limit=200 complete=true next=none
    -- symlink to out-of-workspace directory is rejected --
    failed invalid_input: link_outside_dir: path resolves outside workspace |}]

let%expect_test "directory dispatch and file-only fields" =
  with_fixture @@ fun ~fs ~workspace ->
  print_case "file target reads lines";
  run ~fs ~workspace (input "note.txt");
  print_case "directory target lists";
  run ~fs ~workspace (input "dir");
  print_case "missing directory suggests a sibling";
  run ~fs ~workspace (input "subjectt");
  print_case "if_identity on a directory is rejected";
  run ~fs ~workspace (input ~if_identity:test_identity_string "subject");
  print_case "max_bytes on a directory is ignored";
  run ~fs ~workspace (input ~max_bytes:4 "subject");
  [%expect
    {|
    -- file target reads lines --
    path: note.txt
    contents: "alpha\nbravo\ncharlie\ndelta\n"
    evidence: start=1 returned=4 total=exact 4 status=complete identity=sha256:833940e53452e86ad3cf12deb4054606301b43cec7607677dab4625777c7cee3:26 fingerprint=size=26 mtime_ns=true
    -- directory target lists --
    path: dir
    entries: -
    listing: returned=0 total=0 offset=1 limit=200 complete=true next=none
    -- missing directory suggests a sibling --
    failed not_found: subjectt: path does not exist. Did you mean: subject?
    -- if_identity on a directory is rejected --
    failed invalid_input: subject: if_identity cannot be used with a directory
    -- max_bytes on a directory is ignored --
    path: subject
    entries: dir:.config dir:alpha_dir dir:beta_dir file:.env file:alpha.txt file:beta.txt symlink:dir_link symlink:file_link other:pipe
    listing: returned=9 total=9 offset=1 limit=200 complete=true next=none |}]

let%expect_test "directory text projection" =
  with_fixture @@ fun ~fs ~workspace ->
  let result = Read_file.run ~fs ~workspace (input ~limit:4 "subject") in
  (match Tool.Result.output result with
  | Some output ->
      print_string (Tool.Output.text (Read_file.Output.encode output))
  | None -> failf "read returned no output");
  [%expect
    {|
    subject entries=4/9 offset=1 limit=4 status=partial
    subject/.config/
    subject/alpha_dir/
    subject/beta_dir/
    subject/.env
    next: read_file {"path":"subject","offset":5,"limit":4} |}]

let%expect_test "durable output recovers directory listing" =
  with_fixture @@ fun ~fs ~workspace ->
  let result = Read_file.run ~fs ~workspace (input ~limit:4 "subject") in
  let output =
    match Tool.Result.output result with
    | Some output -> output
    | None -> failf "read_file completed without output"
  in
  print_recovered_output (output_roundtrip (Read_file.Output.encode output));
  [%expect
    {|
    recovered listing path=subject returned=4 total=9 complete=false next=offset:5 limit:4 entries=dir:.config dir:alpha_dir dir:beta_dir file:.env |}]

[%%run_tests "spice.tools.read_file.expect"]
