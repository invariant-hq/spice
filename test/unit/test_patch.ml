(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Patch = Spice_patch

let patch lines = String.concat "\n" lines
let rel path = Spice_path.Rel.to_string path

let pp_apply_mismatch ppf = function
  | Patch.Update.Missing_context context ->
      Format.fprintf ppf "Missing_context %S" context
  | Patch.Update.Missing_lines { old_lines; end_of_file } ->
      Format.fprintf ppf "Missing_lines { old_lines = [%a]; end_of_file = %b }"
        Format.(
          pp_print_list ~pp_sep:(fun ppf () -> fprintf ppf "; ") pp_print_string)
        old_lines end_of_file
  | Patch.Update.Missing_insertion_point { end_of_file } ->
      Format.fprintf ppf "Missing_insertion_point { end_of_file = %b }"
        end_of_file

let pp_apply_error ppf { Patch.Update.chunk; mismatch } =
  Format.fprintf ppf "{ chunk = %d; mismatch = %a }" chunk pp_apply_mismatch
    mismatch

let apply_error = testable ~pp:pp_apply_error ~equal:( = ) ()

let parse text =
  match Patch.parse text with
  | Ok operations -> operations
  | Error error -> failf "parse failed: %a" Patch.Error.pp error

let expect_parse_error text check =
  match Patch.parse text with
  | Ok _ -> failf "expected parse error"
  | Error error -> check error

let expect_message msg error message =
  equal string ~msg:(msg ^ " message") message (Patch.Error.message error)

let parsed_update text =
  match parse text with
  | [ Patch.Operation.Update { update; _ } ] -> update
  | operations ->
      failf "expected one update, got %d operations" (List.length operations)

let apply contents update =
  match Patch.Update.apply update contents with
  | Ok contents -> contents
  | Error error -> failf "apply failed: %a" pp_apply_error error

let expect_apply_error contents update expected =
  equal
    (result string apply_error)
    ~msg:"apply error" (Error expected)
    (Patch.Update.apply update contents)

let parses_operations () =
  let operations =
    parse
      (patch
         [
           "*** Begin Patch";
           "*** Add File: src/new.txt";
           "+hello";
           "+";
           "++literal plus";
           "*** Update File: src/old.txt";
           "*** Move to: src/moved.txt";
           "@@ anchor";
           "-old";
           "+new";
           "*** Delete File: src/gone.txt";
           "*** End Patch";
         ])
  in
  match operations with
  | [
   Patch.Operation.Add { path = add_path; contents };
   Patch.Operation.Update { path = update_path; move_to = Some move_to; update };
   Patch.Operation.Delete { path = delete_path };
  ] ->
      let chunk =
        match Patch.Update.chunks update with
        | [ chunk ] -> chunk
        | chunks -> failf "expected one chunk, got %d" (List.length chunks)
      in
      equal string ~msg:"add path" "src/new.txt" (rel add_path);
      equal string ~msg:"add contents" "hello\n\n+literal plus\n" contents;
      equal string ~msg:"update path" "src/old.txt" (rel update_path);
      equal string ~msg:"move destination" "src/moved.txt" (rel move_to);
      equal (option string) ~msg:"context" (Some "anchor")
        chunk.Patch.Update.context;
      equal (list string) ~msg:"old lines" [ "old" ]
        chunk.Patch.Update.old_lines;
      equal (list string) ~msg:"new lines" [ "new" ]
        chunk.Patch.Update.new_lines;
      equal bool ~msg:"not EOF constrained" false chunk.Patch.Update.end_of_file;
      equal string ~msg:"delete path" "src/gone.txt" (rel delete_path)
  | _ -> failf "unexpected operations"

let parses_update_chunks () =
  let update =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@ first";
           " unchanged";
           "-old";
           "+new";
           "@@ last";
           "+tail";
           "*** End of File";
           "*** End Patch";
         ])
  in
  let chunks = Patch.Update.chunks update in
  match chunks with
  | [ first; last ] ->
      equal (option string) ~msg:"first context" (Some "first")
        first.Patch.Update.context;
      equal (list string) ~msg:"first old" [ "unchanged"; "old" ]
        first.Patch.Update.old_lines;
      equal (list string) ~msg:"first new" [ "unchanged"; "new" ]
        first.Patch.Update.new_lines;
      equal bool ~msg:"first not EOF" false first.Patch.Update.end_of_file;
      equal (option string) ~msg:"last context" (Some "last")
        last.Patch.Update.context;
      equal (list string) ~msg:"last old" [] last.Patch.Update.old_lines;
      equal (list string) ~msg:"last new" [ "tail" ] last.Patch.Update.new_lines;
      equal bool ~msg:"last EOF" true last.Patch.Update.end_of_file
  | chunks -> failf "expected two chunks, got %d" (List.length chunks)

let parses_marker_looking_update_lines_as_content () =
  let update =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           " *** End Patch";
           " *** End of File";
           " *** Update File: other.txt";
           "-old";
           "+new";
           "*** End Patch";
         ])
  in
  match Patch.Update.chunks update with
  | [ chunk ] ->
      equal (list string) ~msg:"old lines"
        [
          "*** End Patch";
          "*** End of File";
          "*** Update File: other.txt";
          "old";
        ]
        chunk.Patch.Update.old_lines;
      equal (list string) ~msg:"new lines"
        [
          "*** End Patch";
          "*** End of File";
          "*** Update File: other.txt";
          "new";
        ]
        chunk.Patch.Update.new_lines;
      equal bool ~msg:"not EOF constrained" false chunk.Patch.Update.end_of_file
  | chunks -> failf "expected one chunk, got %d" (List.length chunks)

let reports_parse_errors_precisely () =
  let cases =
    [
      ( "missing begin",
        "not a patch",
        fun error ->
          (match error with
          | Patch.Error.Invalid_patch _ -> ()
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "missing begin" error
            "line 1: first line must be '*** Begin Patch'" );
      ( "missing end",
        patch [ "*** Begin Patch"; "*** Delete File: x.txt" ],
        fun error ->
          (match error with
          | Patch.Error.Invalid_patch _ -> ()
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "missing end" error "last line must be '*** End Patch'"
      );
      ( "empty patch",
        patch [ "*** Begin Patch"; "*** End Patch" ],
        fun error ->
          (match error with
          | Patch.Error.Empty_patch { line } ->
              equal int ~msg:"empty patch line" 2 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "empty patch" error
            "line 2: patch contains no operations" );
      ( "empty add",
        patch [ "*** Begin Patch"; "*** Add File: x.txt"; "*** End Patch" ],
        fun error ->
          (match error with
          | Patch.Error.Invalid_hunk { line; _ } ->
              equal int ~msg:"empty add line" 2 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "empty add" error
            "line 2: add file hunk must contain at least one line" );
      ( "empty update",
        patch [ "*** Begin Patch"; "*** Update File: x.txt"; "*** End Patch" ],
        fun error ->
          (match error with
          | Patch.Error.Empty_update { line } ->
              equal int ~msg:"empty update line" 2 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "empty update" error
            "line 2: update file hunk must not be empty" );
      ( "EOF-only update",
        patch
          [
            "*** Begin Patch";
            "*** Update File: x.txt";
            "@@";
            "*** End of File";
            "*** End Patch";
          ],
        fun error ->
          (match error with
          | Patch.Error.Empty_update { line } ->
              equal int ~msg:"EOF-only update line" 4 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "EOF-only update" error
            "line 4: update file hunk must not be empty" );
      ( "invalid operation",
        patch [ "*** Begin Patch"; "*** Rename File: x.txt"; "*** End Patch" ],
        fun error ->
          (match error with
          | Patch.Error.Invalid_hunk { line; _ } ->
              equal int ~msg:"invalid operation line" 2 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "invalid operation" error
            "line 2: expected add, delete, or update file hunk" );
      ( "invalid update line",
        patch
          [
            "*** Begin Patch";
            "*** Update File: x.txt";
            "@@";
            "BAD";
            "*** End Patch";
          ],
        fun error ->
          (match error with
          | Patch.Error.Invalid_hunk { line; _ } ->
              equal int ~msg:"invalid update line" 4 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "invalid update line" error
            "line 4: unexpected line in update hunk: \"BAD\"; expected space, \
             +, or -" );
      ( "empty update body line",
        patch
          [
            "*** Begin Patch";
            "*** Update File: x.txt";
            "@@";
            "";
            "*** End Patch";
          ],
        fun error ->
          (match error with
          | Patch.Error.Invalid_hunk { line; _ } ->
              equal int ~msg:"empty update body line" 4 line
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "empty update body line" error
            "line 4: unexpected line in update hunk: \"\"; expected space, +, \
             or -" );
      ( "leading whitespace before patch",
        " \n*** Begin Patch\n*** End Patch",
        fun error ->
          (match error with
          | Patch.Error.Invalid_patch _ -> ()
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "leading whitespace before patch" error
            "line 1: first line must be '*** Begin Patch'" );
      ( "trailing whitespace after patch",
        patch
          [ "*** Begin Patch"; "*** Delete File: x.txt"; "*** End Patch"; " " ],
        fun error ->
          (match error with
          | Patch.Error.Invalid_patch _ -> ()
          | error -> failf "unexpected error: %a" Patch.Error.pp error);
          expect_message "trailing whitespace after patch" error
            "line 4: last line must be '*** End Patch'" );
    ]
  in
  List.iter (fun (_, input, check) -> expect_parse_error input check) cases

let reports_invalid_paths () =
  let check msg input line raw path_error =
    expect_parse_error input (function
      | Patch.Error.Invalid_path
          { line = actual_line; input = actual_input; error } ->
          equal int ~msg:(msg ^ " line") line actual_line;
          equal string ~msg:(msg ^ " path input") raw actual_input;
          equal bool ~msg:(msg ^ " path error") true
            (Spice_path.Error.equal path_error error)
      | error -> failf "%s: unexpected error: %a" msg Patch.Error.pp error)
  in
  check "add absolute path"
    (patch [ "*** Begin Patch"; "*** Add File: /abs"; "+x"; "*** End Patch" ])
    2 "/abs" Spice_path.Error.Absolute;
  check "move escapes root"
    (patch
       [
         "*** Begin Patch";
         "*** Update File: old.txt";
         "*** Move to: ../new.txt";
         "@@";
         "-old";
         "+new";
         "*** End Patch";
       ])
    3 "../new.txt" Spice_path.Error.Escapes_root

let applies_replacements_insertions_and_deletions () =
  let update =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@ before";
           "-old";
           "+new";
           "@@ remove";
           "+inserted";
           "@@";
           "-remove";
           "*** End Patch";
         ])
  in
  equal string ~msg:"mixed update" "before\nnew\nremove\ninserted\n"
    (apply "before\nold\nremove\nremove\n" update)

let applies_chunks_from_the_evolving_search_position () =
  let update =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@ marker";
           "-value";
           "+first";
           "@@ marker";
           "-value";
           "+second";
           "*** End Patch";
         ])
  in
  equal string ~msg:"later chunks search after earlier matches"
    "marker\nfirst\nmarker\nsecond\n"
    (apply "marker\nvalue\nmarker\nvalue\n" update)

let applies_eof_constrained_chunks () =
  let replace_suffix =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           "-old";
           "+new";
           "*** End of File";
           "*** End Patch";
         ])
  in
  equal string ~msg:"EOF replacement changes suffix" "keep\nnew\n"
    (apply "keep\nold\n" replace_suffix);
  expect_apply_error "old\nkeep\n" replace_suffix
    {
      Patch.Update.chunk = 0;
      mismatch =
        Patch.Update.Missing_lines { old_lines = [ "old" ]; end_of_file = true };
    };
  let insert_after_eof_context =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@ anchor";
           "+tail";
           "*** End of File";
           "*** End Patch";
         ])
  in
  equal string ~msg:"EOF insertion after final context" "before\nanchor\ntail\n"
    (apply "before\nanchor\n" insert_after_eof_context);
  expect_apply_error "anchor\nafter\n" insert_after_eof_context
    {
      Patch.Update.chunk = 0;
      mismatch = Patch.Update.Missing_insertion_point { end_of_file = true };
    };
  let insert_at_eof =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           "+tail";
           "*** End of File";
           "*** End Patch";
         ])
  in
  equal string ~msg:"contextless EOF insertion appends to a non-empty file"
    "head\ntail\n" (apply "head\n" insert_at_eof);
  let marker_whitespace =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           "-old";
           "+new";
           "*** End of File  ";
           "*** End Patch";
         ])
  in
  equal string ~msg:"whitespace around EOF marker" "keep\nnew\n"
    (apply "keep\nold\n" marker_whitespace);
  expect_apply_error "old\nkeep\n" marker_whitespace
    {
      Patch.Update.chunk = 0;
      mismatch =
        Patch.Update.Missing_lines { old_lines = [ "old" ]; end_of_file = true };
    }

let preserves_final_newline_state () =
  let update =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           "-old";
           "+new";
           "*** End Patch";
         ])
  in
  equal string ~msg:"missing final newline stays missing" "new"
    (apply "old" update);
  equal string ~msg:"existing final newline stays present" "new\n"
    (apply "old\n" update);
  let insert =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           "+tail";
           "*** End Patch";
         ])
  in
  equal string ~msg:"empty file insertion has no final newline" "tail"
    (apply "" insert)

let reports_apply_mismatches () =
  let update =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@ anchor";
           "-old";
           "+new";
           "*** End Patch";
         ])
  in
  expect_apply_error "body\n" update
    { Patch.Update.chunk = 0; mismatch = Patch.Update.Missing_context "anchor" };
  expect_apply_error "anchor\nother\n" update
    {
      Patch.Update.chunk = 0;
      mismatch =
        Patch.Update.Missing_lines
          { old_lines = [ "old" ]; end_of_file = false };
    };
  let second_chunk_fails =
    parsed_update
      (patch
         [
           "*** Begin Patch";
           "*** Update File: file.txt";
           "@@";
           "-a";
           "+A";
           "@@";
           "-missing";
           "+B";
           "*** End Patch";
         ])
  in
  expect_apply_error "a\nb\n" second_chunk_fails
    {
      Patch.Update.chunk = 1;
      mismatch =
        Patch.Update.Missing_lines
          { old_lines = [ "missing" ]; end_of_file = false };
    }

let () =
  run "spice.patch"
    [
      test "parses operations" parses_operations;
      test "parses update chunks" parses_update_chunks;
      test "parses marker-looking update lines as content"
        parses_marker_looking_update_lines_as_content;
      test "reports parse errors precisely" reports_parse_errors_precisely;
      test "reports invalid paths" reports_invalid_paths;
      test "applies replacements insertions and deletions"
        applies_replacements_insertions_and_deletions;
      test "applies chunks from the evolving search position"
        applies_chunks_from_the_evolving_search_position;
      test "applies EOF-constrained chunks" applies_eof_constrained_chunks;
      test "preserves final newline state" preserves_final_newline_state;
      test "reports apply mismatches" reports_apply_mismatches;
    ]
