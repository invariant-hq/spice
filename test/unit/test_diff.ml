(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Diff = Spice_diff

let label = Diff.Label.of_string
let expect_some msg = function Some value -> value | None -> failf "%s" msg

let equal_stats msg ~files ~additions ~deletions actual =
  equal int ~msg:(msg ^ " files") files actual.Diff.files;
  equal int ~msg:(msg ^ " additions") additions actual.Diff.additions;
  equal int ~msg:(msg ^ " deletions") deletions actual.Diff.deletions

let equal_stats_value msg expected actual =
  equal_stats msg ~files:expected.Diff.files ~additions:expected.Diff.additions
    ~deletions:expected.Diff.deletions actual

let label_gen =
  Gen.map Diff.Label.escaped
    (Gen.string_size (Gen.int_range 0 12)
       (Gen.oneofl [ 'a'; 'b'; 'c'; '/'; '+'; '-'; '\n'; '\r'; '\000' ]))

let text_gen =
  Gen.string_size (Gen.int_range 0 12)
    (Gen.oneofl [ 'a'; 'b'; 'c'; '+'; '-'; ' '; '\n' ])

let numbered_lines count =
  let buffer = Buffer.create (count * 8) in
  for i = 1 to count do
    Buffer.add_string buffer "line ";
    Buffer.add_string buffer (string_of_int i);
    Buffer.add_char buffer '\n'
  done;
  Buffer.contents buffer

let file_change_gen =
  Gen.bind label_gen (fun label ->
      Gen.bind text_gen (fun before ->
          Gen.bind text_gen (fun after ->
              Gen.oneof
                [
                  Gen.pure (Diff.File_change.create ~label ~contents:after);
                  Gen.pure (Diff.File_change.delete ~label ~contents:before);
                  Gen.pure (Diff.File_change.modify ~label ~before ~after);
                ])))

let pp_file_change ppf change =
  Format.fprintf ppf "<change %a>" Diff.Label.pp (Diff.File_change.label change)

let file_change = testable ~pp:pp_file_change ~gen:file_change_gen ()

let label_validation () =
  let file = label "lib/a.ml" in
  equal string ~msg:"label formats as display text" "lib/a.ml"
    (Diff.Label.to_string file);
  is_true ~msg:"equal compares labels"
    (Diff.Label.equal file (label "lib/a.ml"));
  is_true ~msg:"compare agrees with equal"
    (Int.equal 0 (Diff.Label.compare file (label "lib/a.ml")));
  expect_invalid_arg ~expected:"diff label must not be empty"
    "empty labels are rejected" (fun () ->
      Diff.Label.of_string "" |> Diff.Label.to_string);
  expect_invalid_arg ~expected:"diff label is malformed"
    "newline labels are rejected" (fun () ->
      Diff.Label.of_string "a\nb" |> Diff.Label.to_string)

let escaped_labels_are_valid () =
  equal string ~msg:"newlines are escaped" "a\\nb"
    (Diff.Label.to_string (Diff.Label.escaped "a\nb"));
  equal string ~msg:"control characters are escaped" "a\\rb\\000c"
    (Diff.Label.to_string (Diff.Label.escaped "a\rb\000c"));
  equal string ~msg:"empty escaped labels are stable" "<empty>"
    (Diff.Label.to_string (Diff.Label.escaped ""));
  equal string ~msg:"escaped labels are accepted" "a\\nb\\000c"
    (Diff.Label.to_string
       (Diff.Label.of_string
          (Diff.Label.to_string (Diff.Label.escaped "a\nb\000c"))))

let file_change_of_states_maps_all_cases () =
  let label = label "state.txt" in
  equal (option unit) ~msg:"absent states mean no change" None
    (Option.map (Fun.const ())
       (Diff.File_change.of_states ~label ~before:None ~after:None));
  let created =
    expect_some "expected create"
      (Diff.File_change.of_states ~label ~before:None ~after:(Some "new\n"))
  in
  let deleted =
    expect_some "expected delete"
      (Diff.File_change.of_states ~label ~before:(Some "old\n") ~after:None)
  in
  let modified =
    expect_some "expected modify"
      (Diff.File_change.of_states ~label ~before:(Some "old\n")
         ~after:(Some "new\n"))
  in
  equal (option string) ~msg:"created has no before" None
    (Diff.File_change.before created);
  equal (option string) ~msg:"created has after contents" (Some "new\n")
    (Diff.File_change.after created);
  equal (option string) ~msg:"deleted has before contents" (Some "old\n")
    (Diff.File_change.before deleted);
  equal (option string) ~msg:"deleted has no after" None
    (Diff.File_change.after deleted);
  equal_stats "modify state" ~files:1 ~additions:1 ~deletions:1
    (Diff.stats_of_changes [ modified ])

let noop_changes_are_omitted () =
  let diff =
    Diff.render
      [
        Diff.File_change.modify ~label:(label "same.txt") ~before:"same\n"
          ~after:"same\n";
      ]
  in
  is_true ~msg:"unchanged files do not render" (Diff.is_empty diff);
  equal string ~msg:"empty diff has empty text" "" (Diff.to_string diff);
  equal_stats "empty diff has zero stats" ~files:0 ~additions:0 ~deletions:0
    (Diff.stats diff)

let stats_of_changes_match_rendered_stats () =
  let changes =
    [
      Diff.File_change.create ~label:(label "new.txt") ~contents:"new\n";
      Diff.File_change.delete ~label:(label "old.txt") ~contents:"old\n";
      Diff.File_change.modify ~label:(label "changed.txt") ~before:"a\nb\n"
        ~after:"a\nB\n";
      Diff.File_change.modify ~label:(label "same.txt") ~before:"same\n"
        ~after:"same\n";
    ]
  in
  equal_stats_value "stats_of_changes matches render stats"
    (Diff.stats (Diff.render changes))
    (Diff.stats_of_changes changes);
  equal int ~msg:"unlimited render omits nothing" 0
    (Diff.omitted (Diff.render changes))

let pure_creates_and_deletes_count_lines_directly () =
  let line_count = 2_048 in
  let contents = numbered_lines line_count in
  let created =
    Diff.File_change.create ~label:(label "created.txt") ~contents
  in
  let deleted =
    Diff.File_change.delete ~label:(label "deleted.txt") ~contents
  in
  equal_stats "pure stats" ~files:2 ~additions:line_count
    ~deletions:line_count
    (Diff.stats_of_changes [ created; deleted ]);
  let diff = Diff.render ~context:0 [ created; deleted ] in
  equal_stats "pure rendered stats" ~files:2 ~additions:line_count
    ~deletions:line_count (Diff.stats diff);
  equal int ~msg:"pure render omits nothing" 0 (Diff.omitted diff)

let context_must_be_non_negative () =
  expect_invalid_arg ~expected:"context must be non-negative"
    "negative context is rejected" (fun () ->
      Diff.render ~context:(-1) [] |> Diff.to_string)

let limits_must_be_non_negative () =
  expect_invalid_arg ~expected:"max_files must be non-negative"
    "negative max_files is rejected" (fun () ->
      Diff.Limits.make ~max_files:(-1) ~max_file_bytes:0 ~max_lines:0 ()
      |> ignore);
  expect_invalid_arg ~expected:"max_file_bytes must be non-negative"
    "negative max_file_bytes is rejected" (fun () ->
      Diff.Limits.make ~max_files:0 ~max_file_bytes:(-1) ~max_lines:0 ()
      |> ignore);
  expect_invalid_arg ~expected:"max_lines must be non-negative"
    "negative max_lines is rejected" (fun () ->
      Diff.Limits.make ~max_files:0 ~max_file_bytes:0 ~max_lines:(-1) ()
      |> ignore);
  expect_invalid_arg ~expected:"max_edit_distance must be non-negative"
    "negative max_edit_distance is rejected" (fun () ->
      Diff.Limits.make ~max_files:0 ~max_file_bytes:0 ~max_lines:0
        ~max_edit_distance:(-1) ()
      |> ignore)

let limited_render_counts_omitted_files_without_omitted_lines () =
  let byte_limits =
    Diff.Limits.make ~max_files:10 ~max_file_bytes:4 ~max_lines:100 ()
  in
  let byte_limited =
    Diff.render ~limits:byte_limits
      [ Diff.File_change.create ~label:(label "big.txt") ~contents:"hello\n" ]
  in
  equal_stats "byte-limited render stats" ~files:1 ~additions:0 ~deletions:0
    (Diff.stats byte_limited);
  equal int ~msg:"byte-limited render omits one file" 1
    (Diff.omitted byte_limited);
  let file_limits =
    Diff.Limits.make ~max_files:1 ~max_file_bytes:100 ~max_lines:100 ()
  in
  let file_limited =
    Diff.render ~limits:file_limits
      [
        Diff.File_change.create ~label:(label "a.txt") ~contents:"a\n";
        Diff.File_change.create ~label:(label "b.txt") ~contents:"b\n";
      ]
  in
  equal_stats "file-limited render stats" ~files:2 ~additions:1 ~deletions:0
    (Diff.stats file_limited);
  equal int ~msg:"max_files summary counts the elided file" 1
    (Diff.omitted file_limited);
  let line_limits =
    Diff.Limits.make ~max_files:10 ~max_file_bytes:1000 ~max_lines:1 ()
  in
  let line_limited =
    Diff.render ~limits:line_limits
      [
        Diff.File_change.create ~label:(label "many.txt") ~contents:"x\ny\nz\n";
      ]
  in
  equal int ~msg:"line-limited render omits one file" 1
    (Diff.omitted line_limited);
  equal_stats "line-limited render keeps the file, drops the lines" ~files:1
    ~additions:0 ~deletions:0 (Diff.stats line_limited);
  let distance_limits =
    Diff.Limits.make ~max_files:10 ~max_file_bytes:1000 ~max_lines:1000
      ~max_edit_distance:1 ()
  in
  let distance_limited =
    Diff.render ~limits:distance_limits
      [
        Diff.File_change.modify ~label:(label "rewrite.txt") ~before:"a\nb\n"
          ~after:"c\nd\n";
      ]
  in
  equal int ~msg:"edit-distance-limited render omits one file" 1
    (Diff.omitted distance_limited);
  equal_stats "edit-distance-limited render keeps the file, drops the lines"
    ~files:1 ~additions:0 ~deletions:0
    (Diff.stats distance_limited);
  let pure_distance_limited =
    Diff.render ~limits:distance_limits
      [
        Diff.File_change.create ~label:(label "create-rewrite.txt")
          ~contents:"a\nb\n";
      ]
  in
  equal int ~msg:"pure edit-distance-limited render omits one file" 1
    (Diff.omitted pure_distance_limited);
  equal_stats
    "pure edit-distance-limited render keeps the file, drops the lines" ~files:1
    ~additions:0 ~deletions:0
    (Diff.stats pure_distance_limited)

let raw_mode_preserves_file_text () =
  let unsafe_label = Diff.Label.of_string "bad\027.txt" in
  let unsafe_text = "safe\027\226\128\174\n" in
  let diff =
    Diff.render ~mode:`Raw
      [ Diff.File_change.create ~label:unsafe_label ~contents:unsafe_text ]
  in
  equal string ~msg:"raw mode preserves supplied text"
    (String.concat ""
       [
         "--- /dev/null\n";
         "+++ bad\027.txt\n";
         "@@ -0,0 +1,1 @@\n";
         "+safe\027\226\128\174\n";
       ])
    (Diff.to_string diff)

let escaped_label_round_trips text =
  let label = Diff.Label.escaped text in
  let reparsed =
    no_raise (fun () -> Diff.Label.of_string (Diff.Label.to_string label))
  in
  equal string ~msg:"escaped label can be parsed"
    (Diff.Label.to_string label)
    (Diff.Label.to_string reparsed)

let generated_stats_match_rendered_stats changes =
  let diff = Diff.render changes in
  let summary = Diff.stats_of_changes changes in
  equal_stats_value "stats_of_changes matches render stats" summary
    (Diff.stats diff);
  equal int ~msg:"unlimited render omits nothing" 0 (Diff.omitted diff);
  equal bool ~msg:"is_empty matches file count"
    (Int.equal summary.Diff.files 0)
    (Diff.is_empty diff)

let hunk_line_texts hunk =
  List.map
    (fun line -> Format.asprintf "%a" Diff.Hunk.Line.pp line)
    (Diff.Hunk.lines hunk)

let hunk_header hunk =
  match String.split_on_char '\n' (Format.asprintf "%a" Diff.Hunk.pp hunk) with
  | [] -> failf "empty hunk rendering"
  | header :: _ -> header

let hunks_report_positions_and_kinds () =
  let before = "a\nb\nc\nd\ne\nf\ng\n" in
  let after = "a\nb\nc\nx\ne\nf\ng\nh\n" in
  let hunks =
    expect_some "expected hunks" (Diff.hunks ~context:1 ~before ~after ())
  in
  equal int ~msg:"two hunks" 2 (List.length hunks);
  let first = List.nth hunks 0 in
  let second = List.nth hunks 1 in
  equal int ~msg:"first old_start" 3 (Diff.Hunk.old_start first);
  equal int ~msg:"first old_count" 3 (Diff.Hunk.old_count first);
  equal int ~msg:"first new_start" 3 (Diff.Hunk.new_start first);
  equal int ~msg:"first new_count" 3 (Diff.Hunk.new_count first);
  equal (list string) ~msg:"first hunk lines" [ " c"; "-d"; "+x"; " e" ]
    (hunk_line_texts first);
  let removed = List.nth (Diff.Hunk.lines first) 1 in
  equal (option int) ~msg:"removed line keeps its before number" (Some 4)
    (Diff.Hunk.Line.old_line removed);
  equal (option int) ~msg:"removed line has no after number" None
    (Diff.Hunk.Line.new_line removed);
  let added = List.nth (Diff.Hunk.lines first) 2 in
  equal (option int) ~msg:"added line has no before number" None
    (Diff.Hunk.Line.old_line added);
  equal (option int) ~msg:"added line keeps its after number" (Some 4)
    (Diff.Hunk.Line.new_line added);
  equal int ~msg:"second old_start" 7 (Diff.Hunk.old_start second);
  equal int ~msg:"second old_count" 1 (Diff.Hunk.old_count second);
  equal int ~msg:"second new_count" 2 (Diff.Hunk.new_count second);
  let appended = List.nth (Diff.Hunk.lines second) 1 in
  equal (option int) ~msg:"appended line number" (Some 8)
    (Diff.Hunk.Line.new_line appended)

let hunks_merge_touching_context () =
  let before = "a\nb\nc\nd\ne\nf\ng\n" in
  let after = "a\nb\nc\nx\ne\nf\ng\nh\n" in
  let hunks =
    expect_some "expected hunks" (Diff.hunks ~context:3 ~before ~after ())
  in
  equal int ~msg:"touching context ranges merge into one hunk" 1
    (List.length hunks);
  let hunk = List.hd hunks in
  equal int ~msg:"merged old_count" 7 (Diff.Hunk.old_count hunk);
  equal int ~msg:"merged new_count" 8 (Diff.Hunk.new_count hunk)

let hunks_saturate_huge_context () =
  let before = "a\nb\nc\n" in
  let after = "a\nB\nc\n" in
  let hunks =
    expect_some "expected hunks" (Diff.hunks ~context:max_int ~before ~after ())
  in
  equal int ~msg:"huge context produces one hunk" 1 (List.length hunks);
  let hunk = List.hd hunks in
  equal int ~msg:"huge context old_start" 1 (Diff.Hunk.old_start hunk);
  equal int ~msg:"huge context old_count" 3 (Diff.Hunk.old_count hunk);
  equal int ~msg:"huge context new_start" 1 (Diff.Hunk.new_start hunk);
  equal int ~msg:"huge context new_count" 3 (Diff.Hunk.new_count hunk);
  equal (list string) ~msg:"huge context keeps full file"
    [ " a"; "-b"; "+B"; " c" ]
    (hunk_line_texts hunk)

let hunks_mark_pure_insertions () =
  let hunks =
    expect_some "expected hunks"
      (Diff.hunks ~context:0 ~before:"a\nb\n" ~after:"a\nx\nb\n" ())
  in
  equal int ~msg:"one hunk" 1 (List.length hunks);
  let hunk = List.hd hunks in
  equal int ~msg:"insertion covers no before lines" 0 (Diff.Hunk.old_count hunk);
  equal int ~msg:"insertion precedes before line 2" 2 (Diff.Hunk.old_start hunk);
  equal int ~msg:"insertion new_start" 2 (Diff.Hunk.new_start hunk);
  equal int ~msg:"insertion new_count" 1 (Diff.Hunk.new_count hunk);
  equal string ~msg:"header uses the unified empty-range convention"
    "@@ -1,0 +2,1 @@" (hunk_header hunk)

let hunks_of_equal_texts_are_empty () =
  let hunks text =
    expect_some "expected hunks" (Diff.hunks ~before:text ~after:text ())
  in
  equal int ~msg:"equal texts have no hunks" 0 (List.length (hunks "a\nb\n"));
  equal int ~msg:"empty texts have no hunks" 0 (List.length (hunks ""))

let hunks_track_missing_final_newline () =
  let hunks =
    expect_some "expected hunks" (Diff.hunks ~before:"a" ~after:"a\n" ())
  in
  equal int ~msg:"one hunk" 1 (List.length hunks);
  let lines = Diff.Hunk.lines (List.hd hunks) in
  equal (list string) ~msg:"newline change is a real change" [ "-a"; "+a" ]
    (List.map (fun line -> Format.asprintf "%a" Diff.Hunk.Line.pp line) lines);
  is_true ~msg:"removed side has no final newline"
    (not (Diff.Hunk.Line.newline (List.nth lines 0)));
  is_true ~msg:"added side has a final newline"
    (Diff.Hunk.Line.newline (List.nth lines 1))

let hunks_respect_max_edit_distance () =
  equal (option unit) ~msg:"exceeded distance is None" None
    (Option.map (Fun.const ())
       (Diff.hunks ~max_edit_distance:1 ~before:"a\nb\nc\n" ~after:"x\ny\nz\n"
          ()));
  let hunks =
    expect_some "expected hunks"
      (Diff.hunks ~max_edit_distance:6 ~before:"a\nb\nc\n" ~after:"x\ny\nz\n" ())
  in
  equal int ~msg:"distance within limit yields hunks" 1 (List.length hunks);
  expect_invalid_arg ~expected:"context must be non-negative"
    "hunks rejects negative context" (fun () ->
      Diff.hunks ~context:(-1) ~before:"" ~after:"" () |> ignore);
  expect_invalid_arg ~expected:"max_edit_distance must be non-negative"
    "hunks rejects negative max_edit_distance" (fun () ->
      Diff.hunks ~max_edit_distance:(-1) ~before:"" ~after:"" () |> ignore)

let text_pair_gen =
  Gen.bind text_gen (fun before ->
      Gen.map (fun after -> (before, after)) text_gen)

let pp_text_pair ppf (before, after) =
  Format.fprintf ppf "(%S, %S)" before after

let text_pair = testable ~pp:pp_text_pair ~gen:text_pair_gen ()

let generated_hunk_headers_match_render (before, after) =
  let hunks = expect_some "expected hunks" (Diff.hunks ~before ~after ()) in
  let rendered =
    Diff.to_string
      (Diff.render ~mode:`Raw
         [ Diff.File_change.modify ~label:(label "file") ~before ~after ])
  in
  let rendered_headers =
    List.filter
      (String.starts_with ~prefix:"@@")
      (String.split_on_char '\n' rendered)
  in
  equal (list string) ~msg:"hunk headers match rendered headers"
    rendered_headers
    (List.map hunk_header hunks)

let generated_hunk_counts_are_consistent (before, after) =
  let hunks = expect_some "expected hunks" (Diff.hunks ~before ~after ()) in
  List.iter
    (fun hunk ->
      let context, added, removed =
        List.fold_left
          (fun (context, added, removed) line ->
            match Diff.Hunk.Line.kind line with
            | Diff.Hunk.Line.Context -> (context + 1, added, removed)
            | Diff.Hunk.Line.Added -> (context, added + 1, removed)
            | Diff.Hunk.Line.Removed -> (context, added, removed + 1))
          (0, 0, 0) (Diff.Hunk.lines hunk)
      in
      equal int ~msg:"old_count counts context and removed lines"
        (Diff.Hunk.old_count hunk) (context + removed);
      equal int ~msg:"new_count counts context and added lines"
        (Diff.Hunk.new_count hunk) (context + added))
    hunks

let () =
  run "spice.diff"
    [
      test "validates labels" label_validation;
      test "escapes arbitrary labels" escaped_labels_are_valid;
      test "constructs file changes from optional states"
        file_change_of_states_maps_all_cases;
      test "omits no-op changes" noop_changes_are_omitted;
      test "stats_of_changes matches rendered stats"
        stats_of_changes_match_rendered_stats;
      test "pure creates and deletes count lines directly"
        pure_creates_and_deletes_count_lines_directly;
      test "requires non-negative context" context_must_be_non_negative;
      test "requires non-negative limits" limits_must_be_non_negative;
      test "limited render stats omit omitted lines"
        limited_render_counts_omitted_files_without_omitted_lines;
      test "raw mode preserves file text" raw_mode_preserves_file_text;
      test "hunks report positions and kinds" hunks_report_positions_and_kinds;
      test "hunks merge touching context" hunks_merge_touching_context;
      test "hunks saturate huge context" hunks_saturate_huge_context;
      test "hunks mark pure insertions" hunks_mark_pure_insertions;
      test "hunks of equal texts are empty" hunks_of_equal_texts_are_empty;
      test "hunks track missing final newlines"
        hunks_track_missing_final_newline;
      test "hunks respect max_edit_distance" hunks_respect_max_edit_distance;
      prop' "escaped labels round-trip through validation" string
        escaped_label_round_trips;
      prop' "generated hunk headers match rendered headers" text_pair
        generated_hunk_headers_match_render;
      prop' "generated hunk counts are consistent" text_pair
        generated_hunk_counts_are_consistent;
      prop' "generated stats_of_changes match rendered stats" (list file_change)
        generated_stats_match_rendered_stats;
    ]
